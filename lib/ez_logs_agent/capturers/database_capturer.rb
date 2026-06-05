# frozen_string_literal: true

module EzLogsAgent
  module Capturers
    # Captures database operations via ActiveRecord model lifecycle callbacks.
    #
    # This capturer:
    # - Installs after_create, after_update, after_destroy callbacks on ActiveRecord::Base
    # - Captures model class, record id, and operation type
    # - Extracts resource_ids from the model instance
    # - For updates, extracts curated business-relevant change context
    # - Preserves correlation_id from current context
    # - Never crashes the host application (fail-open)
    # - Respects capture_database configuration flag
    #
    # == What This Capturer Does NOT Do
    #
    # - Parse SQL queries
    # - Dump full attribute diffs
    # - Include sensitive data
    # - Guess actors
    # - Act as an audit log
    #
    # == Event Shape
    #
    # Produces events with:
    # - source_type: :database_callback
    # - source_data: { model_class: "User", operation: "create|update|destroy" }
    # - outcome: :success
    # - correlation_id: EzLogsAgent::Correlation.current (if present)
    # - resource_ids: [{ resource_type: "User", resource_id: "123" }]
    # - context: { changes: [{ attribute: "status", from: "pending", to: "shipped" }, ...] } (updates only, if meaningful)
    #
    class DatabaseCapturer
      # Attributes to always ignore when detecting business changes
      IGNORED_ATTRIBUTES = %w[
        id
        created_at
        updated_at
        lock_version
        encrypted_password
        reset_password_token
        reset_password_sent_at
        remember_created_at
        confirmation_token
        confirmed_at
        confirmation_sent_at
        unconfirmed_email
        unlock_token
        locked_at
        sign_in_count
        current_sign_in_at
        last_sign_in_at
        current_sign_in_ip
        last_sign_in_ip
      ].freeze

      # Foreign key changes are now captured because they represent meaningful
      # relationship changes (e.g., profile_id, user_id).
      # Previously we filtered them out, but this loses important context.
      # FOREIGN_KEY_PATTERN = /_id\z/  # Removed January 2026

      # Sensitive-attribute name pattern denylist (secondary defense after
      # `encrypts :foo` introspection) lives in EzLogsAgent::SensitivePatterns —
      # see sensitive_attribute? below.

      @installed = false
      @callbacks_registered = false

      class << self
        # Installs ActiveRecord lifecycle callbacks for database capture.
        #
        # This method is idempotent and can be called multiple times safely.
        # Only installs if ActiveRecord is present.
        #
        # @return [void]
        def install
          return unless defined?(ActiveRecord::Base)
          return if @installed

          # Memoize config values that the per-row hot path reads on
          # every callback. Without this, each captured create / update
          # / destroy pays a method dispatch into the configuration
          # object (`EzLogsAgent.configuration.capture_database`) plus
          # an `all_excluded_tables.include?` Hash dispatch. On a request
          # that touches dozens of rows the overhead is real.
          # Runtime mutations require uninstall! + install to take effect
          # (acceptable — nobody flips capture_database at runtime).
          @capture_enabled =
            begin
              EzLogsAgent.configuration.capture_database
            rescue StandardError
              false
            end
          @excluded_tables =
            begin
              EzLogsAgent.configuration.all_excluded_tables.dup.freeze
            rescue StandardError
              [].freeze
            end
          @display_name_for =
            begin
              (EzLogsAgent.configuration.display_name_for || {}).dup.freeze
            rescue StandardError
              {}.freeze
            end

          # Only register callbacks once per Ruby process
          unless @callbacks_registered
            ActiveRecord::Base.class_eval do
              after_create { |model| EzLogsAgent::Capturers::DatabaseCapturer.handle_create(model) }
              after_update { |model| EzLogsAgent::Capturers::DatabaseCapturer.handle_update(model) }
              after_destroy { |model| EzLogsAgent::Capturers::DatabaseCapturer.handle_destroy(model) }
            end
            @callbacks_registered = true
          end

          @installed = true
          EzLogsAgent::Logger.debug("[DatabaseCapturer] Installed")
        rescue StandardError => e
          EzLogsAgent::Logger.error("[DatabaseCapturer] Installation failed: #{e.class} - #{e.message}")
        end

        # Handles after_create callback
        #
        # @param model [ActiveRecord::Base] The created model instance
        # @return [void]
        def handle_create(model)
          return unless capture_enabled?

          context = extract_initial_attributes(model) || {}
          context[:display_name] = resolve_display_name(model)
          capture_event(model, "create", context: context.presence)
        rescue StandardError => e
          EzLogsAgent::Logger.error("[DatabaseCapturer] handle_create failed: #{e.class} - #{e.message}")
        end

        # Handles after_update callback
        #
        # @param model [ActiveRecord::Base] The updated model instance
        # @return [void]
        def handle_update(model)
          return unless capture_enabled?

          context = extract_change_context(model) || {}
          context[:display_name] = resolve_display_name(model)
          capture_event(model, "update", context: context.presence)
        rescue StandardError => e
          EzLogsAgent::Logger.error("[DatabaseCapturer] handle_update failed: #{e.class} - #{e.message}")
        end

        # Handles after_destroy callback
        #
        # @param model [ActiveRecord::Base] The destroyed model instance
        # @return [void]
        def handle_destroy(model)
          return unless capture_enabled?

          context = { display_name: resolve_display_name(model) }
          capture_event(model, "destroy", context: context.presence)
        rescue StandardError => e
          EzLogsAgent::Logger.error("[DatabaseCapturer] handle_destroy failed: #{e.class} - #{e.message}")
        end

        private

        # Checks if database capture is enabled. Reads the memoized
        # value set at install time (no config-object dispatch on the
        # hot path).
        #
        # @return [Boolean]
        def capture_enabled?
          @capture_enabled
        end

        # Checks if the model's table is in the excluded_tables list.
        # Reads the memoized list set at install time.
        #
        # @param model [ActiveRecord::Base] The model instance
        # @return [Boolean]
        def table_excluded?(model)
          return false unless model.class.respond_to?(:table_name)

          @excluded_tables.include?(model.class.table_name)
        rescue StandardError
          false
        end

        # Captures a database event and pushes to buffer
        #
        # @param model [ActiveRecord::Base] The model instance
        # @param operation [String] The operation type ("create", "update", "destroy")
        # @param context [Hash, nil] Optional context with change information
        # @return [void]
        def capture_event(model, operation, context: nil)
          return if table_excluded?(model)

          event = EzLogsAgent::EventBuilder.build(
            source_type: :database_callback,
            source_data: {
              model_class: model.class.name,
              operation: operation
            },
            outcome: :success,
            correlation_id: EzLogsAgent::Correlation.current,
            resource_ids: extract_resource_ids(model),
            context: context,
            duration_ms: nil
          )

          EzLogsAgent::Buffer.push(event)
        rescue StandardError => e
          EzLogsAgent::Logger.error("[DatabaseCapturer] capture_event failed: #{e.class} - #{e.message}")
        end

        # Extracts resource_ids from model
        #
        # @param model [ActiveRecord::Base] The model instance
        # @return [Array<Hash>] Array with single resource identifier
        def extract_resource_ids(model)
          [
            {
              resource_type: model.class.name,
              resource_id: model.id.to_s
            }
          ]
        rescue StandardError
          []
        end

        # Resolves a human-readable display name for a model instance
        #
        # Uses configuration if provided, otherwise falls back to common patterns:
        # 1. Custom field from config.display_name_for[ModelClass]
        # 2. model.name (if responds)
        # 3. model.title (if responds)
        # 4. model.number (if responds)
        #
        # Returns nil if no meaningful name found. The frontend can decide
        # to show the resource ID as a fallback if needed.
        #
        # IMPORTANT: This method only reads attributes already loaded in memory.
        # It does NOT trigger any database queries.
        # Configured fields should be direct attributes, not associations.
        #
        # @param model [ActiveRecord::Base] The model instance
        # @return [String, nil] The display name, or nil if no meaningful name found
        def resolve_display_name(model)
          # Check for configured custom field (memoized list, see install).
          custom_field = @display_name_for[model.class.name]

          if custom_field && model.respond_to?(custom_field)
            value = model.public_send(custom_field)
            return value.to_s if value.present?
          end

          # Fallback chain: name → title → number
          if model.respond_to?(:name) && model.name.present?
            return model.name.to_s
          end

          if model.respond_to?(:title) && model.title.present?
            return model.title.to_s
          end

          if model.respond_to?(:number) && model.number.present?
            return model.number.to_s
          end

          # No meaningful name found - return nil
          # Frontend can show resource ID as fallback if needed
          nil
        rescue StandardError => e
          EzLogsAgent::Logger.error("[DatabaseCapturer] resolve_display_name failed: #{e.class} - #{e.message}")
          nil
        end

        # Extracts curated business change context from model's saved_changes
        #
        # Rules:
        # - Only for updates
        # - Pick meaningful attributes (ignore technical fields)
        # - Ignore foreign keys
        # - Ignore sensitive data
        # - Only scalar values (String, Integer, Float, Boolean, Symbol, NilClass)
        # - Value must have actually changed (from != to, not both nil)
        #
        # @param model [ActiveRecord::Base] The updated model instance
        # @return [Hash, nil] Context hash with change, or nil if no meaningful change
        def extract_change_context(model)
          return nil unless model.respond_to?(:saved_changes)

          changes = model.saved_changes
          return nil if changes.nil? || changes.empty?

          # Find meaningful changes (excludes encrypted columns + sensitive
          # name patterns — see meaningful_attribute? / encrypted_attribute?)
          meaningful_changes = filter_meaningful_changes(changes, model)
          return nil if meaningful_changes.empty?

          # Build context with all meaningful changes
          build_change_context(meaningful_changes)
        rescue StandardError => e
          EzLogsAgent::Logger.error("[DatabaseCapturer] extract_change_context failed: #{e.class} - #{e.message}")
          nil
        end

        # Extracts initial attributes from a newly created model
        #
        # Uses the same filtering rules as update changes:
        # - Only meaningful attributes (not technical/ignored)
        # - Only scalar values
        # - Skip nil values (no point recording "attribute: nil")
        # - Skip foreign keys and sensitive data
        #
        # @param model [ActiveRecord::Base] The created model instance
        # @return [Hash, nil] Context hash with initial_attributes, or nil if none
        def extract_initial_attributes(model)
          return nil unless model.respond_to?(:attributes)

          attributes = model.attributes
          return nil if attributes.nil? || attributes.empty?

          # Filter to meaningful, non-nil scalar attributes
          meaningful_attrs = attributes.select do |attribute, value|
            meaningful_attribute?(attribute, model) &&
              scalar?(value) &&
              !value.nil?
          end

          return nil if meaningful_attrs.empty?

          # Format values for JSON
          formatted_attrs = meaningful_attrs.transform_values { |v| format_value_for_json(v) }

          { initial_attributes: formatted_attrs }
        rescue StandardError => e
          EzLogsAgent::Logger.error("[DatabaseCapturer] extract_initial_attributes failed: #{e.class} - #{e.message}")
          nil
        end

        # Filters changes to only meaningful business attributes
        #
        # @param changes [Hash] The saved_changes hash
        # @param model [ActiveRecord::Base] The model instance (used to
        #   consult `record.class.encrypted_attributes` so columns declared
        #   `encrypts :foo` are never captured, regardless of their name).
        # @return [Array<Array>] Array of [attribute, [from, to]] pairs
        def filter_meaningful_changes(changes, model)
          changes.select do |attribute, (from, to)|
            meaningful_attribute?(attribute, model) &&
              scalar_values?(from, to) &&
              values_actually_changed?(from, to)
          end.to_a
        end

        # Checks if an attribute is meaningful (not technical/ignored).
        #
        # @param attribute [String] The attribute name
        # @param model [ActiveRecord::Base, nil] The model instance — when
        #   supplied, columns declared `encrypts :foo` on the model class
        #   are dropped regardless of name. Authoritative drop: if the host
        #   app encrypted the column, we never capture it.
        # @return [Boolean]
        def meaningful_attribute?(attribute, model = nil)
          attr_str = attribute.to_s

          # Skip explicitly ignored attributes
          return false if IGNORED_ATTRIBUTES.include?(attr_str)

          # Foreign keys (_id) are now captured because they represent meaningful
          # relationship changes (e.g., assigned_to_id changing from user A to user B)
          # Previously filtered via FOREIGN_KEY_PATTERN - removed January 2026

          # Authoritative: drop anything the host app declared `encrypts` on.
          # Rails decrypts at the attribute layer before saved_changes fires,
          # so without this check the plaintext would land on the wire.
          return false if model && encrypted_attribute?(attr_str, model)

          # Skip name-pattern-sensitive data (legacy / non-encrypts paths).
          return false if sensitive_attribute?(attr_str)

          true
        end

        # Checks whether the host app declared `encrypts :<attribute>` on
        # this model's class. Delegates to EncryptedAttributes (single
        # source of truth shared with BulkDatabaseCapturer, which only has
        # the class — no instance — for bulk operations).
        #
        # @param attribute [String] The attribute name (already to_s'd)
        # @param model [ActiveRecord::Base] The model instance
        # @return [Boolean]
        def encrypted_attribute?(attribute, model)
          EzLogsAgent::EncryptedAttributes.attribute?(model.class, attribute)
        end

        # Checks if attribute name contains sensitive patterns.
        # Delegates to SensitivePatterns (single source of truth shared
        # with Sanitizer and BulkDatabaseCapturer).
        #
        # @param attribute [String] The attribute name
        # @return [Boolean]
        def sensitive_attribute?(attribute)
          EzLogsAgent::SensitivePatterns.match?(attribute)
        end

        # Checks if both values are scalar types
        #
        # @param from [Object] The old value
        # @param to [Object] The new value
        # @return [Boolean]
        def scalar_values?(from, to)
          scalar?(from) && scalar?(to)
        end

        # Checks if a value is a scalar type (simple, serializable values)
        #
        # Includes Date/Time types which are meaningful business values
        # (e.g., discarded_at for soft deletes, published_at, expires_at)
        #
        # Includes BigDecimal which Rails uses for decimal columns
        # (e.g., prices, percentages, rates)
        #
        # Includes arrays of scalar values (e.g., PostgreSQL array columns
        # like email lists)
        #
        # @param value [Object] The value to check
        # @return [Boolean]
        def scalar?(value)
          return true if value.nil? ||
            value.is_a?(String) ||
            value.is_a?(Integer) ||
            value.is_a?(Float) ||
            value.is_a?(BigDecimal) ||
            value.is_a?(TrueClass) ||
            value.is_a?(FalseClass) ||
            value.is_a?(Symbol) ||
            value.is_a?(Date) ||
            value.is_a?(Time)
          # Note: DateTime inherits from Date, so Date check covers it

          # Arrays of scalars are also allowed (e.g., email arrays)
          return value.all? { |v| scalar?(v) } if value.is_a?(Array)

          false
        end

        # Checks if values actually changed (not both nil)
        #
        # @param from [Object] The old value
        # @param to [Object] The new value
        # @return [Boolean]
        def values_actually_changed?(from, to)
          # Both nil means no real change
          return false if from.nil? && to.nil?

          # Values must be different
          from != to
        end

        # Builds context hash with all meaningful changes
        #
        # Captures ALL meaningful changes for better visibility:
        # - Shows what actually changed in the UI
        # - Enables better event descriptions
        # - Still excludes sensitive/technical fields
        # - Formats Date/Time values as ISO strings for JSON serialization
        #
        # @param meaningful_changes [Array<Array>] Array of [attribute, [from, to]] pairs
        # @return [Hash] Context hash with changes array
        def build_change_context(meaningful_changes)
          changes = meaningful_changes.map do |attribute, (from, to)|
            {
              attribute: attribute.to_s,
              from: format_value_for_json(from),
              to: format_value_for_json(to)
            }
          end

          { changes: changes }
        end

        # Formats a value for JSON serialization
        #
        # Date/Time values are converted to ISO 8601 strings
        # BigDecimal values are converted to floats (JSON doesn't support BigDecimal)
        # Arrays are recursively formatted
        # Other values pass through unchanged
        #
        # @param value [Object] The value to format
        # @return [Object] The formatted value
        def format_value_for_json(value)
          case value
          when Time, DateTime
            value.iso8601
          when Date
            value.to_s
          when BigDecimal
            value.to_f
          when Array
            value.map { |v| format_value_for_json(v) }
          else
            value
          end
        end
      end
    end
  end
end
