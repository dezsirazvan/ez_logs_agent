# frozen_string_literal: true

require "time"

module EzLogsAgent
  # EventBuilder constructs valid Event hashes according to the Event Structure contract.
  #
  # This is a pure, side-effect-free builder that:
  # - Validates required fields
  # - Validates enum values
  # - Enforces conditional rules (outcome ↔ error_message)
  # - Sanitizes sensitive data
  # - Returns a valid Event hash
  #
  # EventBuilder does NOT:
  # - Buffer or send Events
  # - Generate correlation IDs
  # - Interact with Rails or ActiveRecord
  # - Mutate global state
  #
  # @see docs/agent/event_structure.md for complete specification
  module EventBuilder
    # Sensitive keys that should be filtered from source_data and context
    SENSITIVE_KEYS = %w[password token secret api_key credit_card].freeze

    # Valid source types
    VALID_SOURCE_TYPES = %w[http_request background_job database_callback].freeze

    # Valid outcome values
    VALID_OUTCOMES = %w[success failure].freeze

    # Builds a valid Event hash
    #
    # @param source_type [String, Symbol] Event source type (http_request, background_job, database_callback)
    # @param source_data [Hash] Technical details about the event source
    # @param outcome [String, Symbol] Event outcome (success, failure)
    # @param correlation_id [String, nil] Optional correlation identifier
    # @param resource_ids [Array<Hash>] Optional array of resource identifiers
    # @param context [Hash, nil] Optional human-readable context
    # @param duration_ms [Integer, nil] Optional operation duration in milliseconds
    # @param error_message [String, nil] Optional error message (required if outcome is failure)
    # @param timestamp [String, Time, nil] Optional timestamp (defaults to current time)
    #
    # @return [Hash] Valid Event hash
    # @raise [ArgumentError] If validation fails
    #
    # @example Building an HTTP request event
    #   EventBuilder.build(
    #     source_type: "http_request",
    #     source_data: { method: "POST", path: "/api/users", status_code: 201 },
    #     outcome: "success",
    #     duration_ms: 124
    #   )
    #
    def self.build(
      source_type:,
      source_data:,
      outcome:,
      correlation_id: nil,
      resource_ids: [],
      context: nil,
      duration_ms: nil,
      error_message: nil,
      timestamp: nil
    )
      # Validate and normalize inputs
      validated_source_type = validate_source_type!(source_type)
      validated_source_data = validate_source_data!(source_data)
      validated_outcome = validate_outcome!(outcome)
      validated_timestamp = validate_timestamp!(timestamp)
      validated_resource_ids = validate_resource_ids!(resource_ids)
      validated_context = validate_context!(context)
      validated_duration_ms = validate_duration_ms!(duration_ms)

      # Validate conditional rules
      validate_outcome_error_consistency!(validated_outcome, error_message)

      # Sanitize sensitive data
      sanitized_source_data = sanitize_hash(validated_source_data)
      sanitized_context = validated_context.nil? ? nil : sanitize_hash(validated_context)

      # Build and return Event hash
      {
        timestamp: validated_timestamp,
        source_type: validated_source_type,
        source_data: sanitized_source_data,
        outcome: validated_outcome,
        correlation_id: correlation_id,
        resource_ids: validated_resource_ids,
        context: sanitized_context,
        duration_ms: validated_duration_ms,
        error_message: error_message
      }
    end

    # Validates source_type field
    # @param source_type [String, Symbol]
    # @return [String] Validated source type string
    # @raise [ArgumentError]
    def self.validate_source_type!(source_type)
      raise ArgumentError, "source_type is required" if source_type.nil?

      # Normalize symbol to string
      normalized = source_type.to_s

      unless VALID_SOURCE_TYPES.include?(normalized)
        raise ArgumentError,
              "source_type must be one of #{VALID_SOURCE_TYPES.join(', ')}, got: #{normalized}"
      end

      normalized
    end
    private_class_method :validate_source_type!

    # Validates source_data field
    # @param source_data [Hash]
    # @return [Hash] Validated source data
    # @raise [ArgumentError]
    def self.validate_source_data!(source_data)
      raise ArgumentError, "source_data is required" if source_data.nil?
      raise ArgumentError, "source_data must be a Hash, got: #{source_data.class}" unless source_data.is_a?(Hash)

      source_data
    end
    private_class_method :validate_source_data!

    # Validates outcome field
    # @param outcome [String, Symbol]
    # @return [String] Validated outcome string
    # @raise [ArgumentError]
    def self.validate_outcome!(outcome)
      raise ArgumentError, "outcome is required" if outcome.nil?

      # Normalize symbol to string
      normalized = outcome.to_s

      unless VALID_OUTCOMES.include?(normalized)
        raise ArgumentError,
              "outcome must be one of #{VALID_OUTCOMES.join(', ')}, got: #{normalized}"
      end

      normalized
    end
    private_class_method :validate_outcome!

    # Validates and normalizes timestamp
    # @param timestamp [String, Time, nil]
    # @return [String] ISO 8601 timestamp string
    # @raise [ArgumentError]
    def self.validate_timestamp!(timestamp)
      return Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ") if timestamp.nil?

      case timestamp
      when String
        # Validate ISO 8601 format by attempting to parse
        begin
          Time.iso8601(timestamp)
        rescue ArgumentError
          raise ArgumentError, "timestamp must be valid ISO 8601 format, got: #{timestamp}"
        end
        timestamp
      when Time
        timestamp.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
      else
        raise ArgumentError, "timestamp must be a String or Time, got: #{timestamp.class}"
      end
    end
    private_class_method :validate_timestamp!

    # Validates resource_ids field
    # @param resource_ids [Array]
    # @return [Array] Validated resource_ids array
    # @raise [ArgumentError]
    def self.validate_resource_ids!(resource_ids)
      raise ArgumentError, "resource_ids must be an Array, got: #{resource_ids.class}" unless resource_ids.is_a?(Array)

      resource_ids.each_with_index do |resource, index|
        unless resource.is_a?(Hash)
          raise ArgumentError,
                "resource_ids[#{index}] must be a Hash, got: #{resource.class}"
        end

        unless resource.key?(:resource_type) && resource.key?(:resource_id)
          raise ArgumentError,
                "resource_ids[#{index}] must have :resource_type and :resource_id keys, got: #{resource.keys.inspect}"
        end

        unless resource[:resource_type].is_a?(String)
          raise ArgumentError,
                "resource_ids[#{index}][:resource_type] must be a String, got: #{resource[:resource_type].class}"
        end

        unless resource[:resource_id].is_a?(String)
          raise ArgumentError,
                "resource_ids[#{index}][:resource_id] must be a String, got: #{resource[:resource_id].class}"
        end
      end

      resource_ids
    end
    private_class_method :validate_resource_ids!

    # Validates context field
    # @param context [Hash, nil]
    # @return [Hash, nil] Validated context
    # @raise [ArgumentError]
    def self.validate_context!(context)
      return nil if context.nil?

      unless context.is_a?(Hash)
        raise ArgumentError, "context must be a Hash or nil, got: #{context.class}"
      end

      context
    end
    private_class_method :validate_context!

    # Validates duration_ms field
    # @param duration_ms [Integer, nil]
    # @return [Integer, nil] Validated duration_ms
    # @raise [ArgumentError]
    def self.validate_duration_ms!(duration_ms)
      return nil if duration_ms.nil?

      unless duration_ms.is_a?(Integer)
        raise ArgumentError, "duration_ms must be an Integer, got: #{duration_ms.class}"
      end

      if duration_ms.negative?
        raise ArgumentError, "duration_ms must be >= 0, got: #{duration_ms}"
      end

      duration_ms
    end
    private_class_method :validate_duration_ms!

    # Validates outcome and error_message consistency
    # @param outcome [String]
    # @param error_message [String, nil]
    # @raise [ArgumentError]
    def self.validate_outcome_error_consistency!(outcome, error_message)
      if outcome == "failure"
        if error_message.nil? || error_message.empty?
          raise ArgumentError, "error_message is required when outcome is 'failure'"
        end
      elsif outcome == "success"
        unless error_message.nil?
          raise ArgumentError, "error_message must be nil when outcome is 'success'"
        end
      end
    end
    private_class_method :validate_outcome_error_consistency!

    # Recursively sanitizes a hash by filtering sensitive keys
    # @param hash [Hash]
    # @return [Hash] Sanitized hash with sensitive values replaced
    def self.sanitize_hash(hash)
      hash.each_with_object({}) do |(key, value), result|
        if sensitive_key?(key)
          result[key] = "[FILTERED]"
        elsif value.is_a?(Hash)
          result[key] = sanitize_hash(value)
        elsif value.is_a?(Array)
          result[key] = value.map { |item| item.is_a?(Hash) ? sanitize_hash(item) : item }
        else
          result[key] = value
        end
      end
    end
    private_class_method :sanitize_hash

    # Checks if a key is sensitive (case-insensitive substring match)
    # @param key [String, Symbol]
    # @return [Boolean]
    def self.sensitive_key?(key)
      key_str = key.to_s.downcase
      SENSITIVE_KEYS.any? { |sensitive| key_str.include?(sensitive) }
    end
    private_class_method :sensitive_key?
  end
end
