# frozen_string_literal: true

require "active_support/notifications"

module EzLogsAgent
  module Capturers
    # Captures bulk SQL operations that bypass ActiveRecord lifecycle
    # callbacks: delete_all, update_all, insert_all, upsert_all.
    #
    # ## Why this exists
    #
    # DatabaseCapturer (the per-row sibling) hooks after_create/_update/_destroy
    # to capture rich per-record context (saved_changes, encrypted_attributes,
    # display_name). That model breaks for bulk ops — Rails issues a single
    # UPDATE/DELETE/INSERT statement against the database WITHOUT instantiating
    # records, so the callbacks never fire. Customer code like
    #
    #     Order.where(status: "cart").delete_all
    #     Library.where(closed: true).update_all(status: "active")
    #     User.insert_all([{name: "a"}, {name: "b"}])
    #
    # plus `dependent: :delete_all` cascades during a parent destroy, are all
    # invisible to the callback-based path. This capturer fills the gap.
    #
    # ## How it works
    #
    # Subscribes to "sql.active_record" — the standard Rails instrumentation
    # API every observability tool uses (Datadog APM, AppSignal, Skylight).
    # On every SQL statement the host app runs, we get a payload with
    # the raw SQL, binds, name, and row_count. We filter aggressively
    # to ONLY four operations (delete_all / update_all / insert_all /
    # upsert_all) by SQL shape detection (BulkSqlParser.detect_operation),
    # then parse + sanitize + ship.
    #
    # ## Dedup vs DatabaseCapturer
    #
    # Per-row CRUD (`user.save`, `order.destroy`) fires `after_*` callbacks
    # AND produces an `sql.active_record` notification with a singular name
    # ("User Update", "Order Destroy"). DatabaseCapturer captures these via
    # callbacks; this capturer ignores them because their SQL shape is NOT
    # one of the four bulk operations. Mutually exclusive — no double-capture.
    #
    # Cascade case: `Company has_many :orders, dependent: :delete_all` issues
    # a single DELETE for the children. Callbacks don't fire on the children
    # (delete_all bypasses them by design), but this capturer catches the
    # bulk DELETE. The parent's `after_destroy` is captured separately by
    # DatabaseCapturer. Both events share the request's correlation_id and
    # land under the same Action shell. Reader sees parent + cascade as
    # sibling rows on the timeline — the right narrative.
    #
    # ## Wire shape (matches server EventIngest expectations)
    #
    #   {
    #     source_type: "bulk_database",
    #     source_data: {
    #       model_class: "Order",
    #       operation: "delete_all" | "update_all" | "insert_all" | "upsert_all",
    #       row_count: 50000,
    #       where_template: "\"orders\".\"status\" = $1",
    #       where_binds: [{column: "status", value: "cart"}],
    #       set: {"status" => "paid"},        # only update_all
    #       columns: ["name", "email"]        # only insert_all / upsert_all
    #     },
    #     correlation_id: ...,
    #     resource_ids: [{resource_type: "Order", resource_id: "bulk:50000"}],
    #     outcome: "success",
    #     duration_ms: <finish - start>
    #   }
    #
    # The "bulk:<count>" sentinel resource_id is required because the server's
    # ResourceAggregationStage drops entries with nil resource_id. The
    # display layer detects the sentinel and renders "Order (50,000 rows)"
    # without a clickable entity link.
    module BulkDatabaseCapturer
      # AR's `payload[:name]` convention for the four bulk operations
      # (verified against Rails 7.0–8.0 + SQLite/PG/MySQL):
      #
      #   delete_all  → "<Model> Delete All"
      #   update_all  → "<Model> Update All"
      #   insert_all  → "<Model> Insert"   (or "<Model> Bulk Insert" on older PG)
      #   upsert_all  → "<Model> Upsert"   (or "<Model> Bulk Upsert" on older PG)
      #
      # Per-row CRUD uses singular operation verbs:
      #   user.save (new)     → "<Model> Create"
      #   user.update         → "<Model> Update"  (no " All")
      #   user.destroy        → "<Model> Destroy"
      #
      # So the four bulk shapes are uniquely identified by either:
      #   - ending in " All" (covers Delete All / Update All), OR
      #   - the words Insert / Upsert (which are NEVER used for per-row CRUD
      #     — per-row inserts are tagged "Create", per-row updates "Update").
      #
      # SQL shape detection (BulkSqlParser.detect_operation) is the actual
      # authority — this filter is only a sub-µs pre-pass to skip non-bulk
      # notifications without parsing SQL.
      BULK_NAME_HINT = / All\z| (Bulk )?(Insert|Upsert)\z/.freeze

      class << self
        attr_reader :subscriber

        # Installs the AS::Notifications subscription. Idempotent — calling
        # twice is a no-op (would otherwise produce double-events because
        # AS::Notifications.subscribe is itself NOT idempotent).
        #
        # Called from Railtie.install_database_capturer alongside the
        # per-row DatabaseCapturer.install. Both gated by the same
        # `capture_database` configuration flag — no new toggle.
        def install
          return if @installed

          @subscriber = ::ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
            payload = args.last
            event_name = args.first
            started = args[1]
            finished = args[2]
            handle_notification(event_name, started, finished, payload)
          end
          @installed = true
        end

        # Removes the subscription. Specs use this between examples to
        # avoid leaked subscribers; production never calls it.
        def uninstall!
          ::ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
          @subscriber = nil
          @installed = false
        end

        # Per-notification entry point. Wraps everything in `rescue Exception`
        # because an AS::N handler that raises pollutes the host's subscriber
        # chain and (depending on the chain order) can break OTHER observability
        # tools listening on the same channel. Hard rule: bulk capture failures
        # never propagate.
        def handle_notification(_event_name, started, finished, payload)
          return unless capture_enabled?
          return unless eligible_payload?(payload)

          operation = ::EzLogsAgent::BulkSqlParser.detect_operation(payload[:sql])
          return unless operation

          model_class = resolve_model_class(payload[:sql])
          return if model_class.nil?
          return if table_excluded?(model_class)

          parse_result = ::EzLogsAgent::BulkSqlParser.parse(
            sql: payload[:sql],
            type_casted_binds: payload[:type_casted_binds]
          )

          source_data = build_source_data(
            operation: operation,
            model_class: model_class,
            row_count: payload[:row_count],
            parse_result: parse_result
          )

          duration_ms = ((finished - started) * 1000).to_i

          event = ::EzLogsAgent::EventBuilder.build(
            source_type: :bulk_database,
            source_data: source_data,
            outcome: :success,
            correlation_id: ::EzLogsAgent::Correlation.current,
            resource_ids: build_resource_ids(model_class, source_data[:row_count]),
            context: nil,
            duration_ms: duration_ms
          )

          ::EzLogsAgent::Buffer.push(event)
        rescue Exception => e # rubocop:disable Lint/RescueException
          # See class comment: a raise from an AS::N handler hurts other
          # subscribers, so we swallow EVERYTHING (not just StandardError).
          # Logged at error level so a regression surfaces in customer
          # debug output, but never re-raised.
          safe_log_error("handle_notification", e)
        end

        # Fast pre-filter — checks the name field WITHOUT touching SQL.
        # Returns false for the vast majority of notifications (per-row
        # CRUD, SCHEMA, TRANSACTION, internal lookups).
        #
        # @param payload [Hash, nil]
        # @return [Boolean]
        def eligible_payload?(payload)
          return false unless payload.is_a?(Hash)

          name = payload[:name].to_s
          return false if name.empty?

          BULK_NAME_HINT.match?(name)
        end

        # Looks up the model class from the SQL's table name. Returns nil
        # for SQL we can't attribute (raw multi-table queries, anonymous
        # adapter SQL, schema introspection). Skipping these is correct —
        # we'd have nothing to display anyway.
        def resolve_model_class(sql)
          return nil if sql.nil?

          table = extract_table_name(sql)
          return nil if table.nil?

          ::ActiveRecord::Base.descendants.find do |klass|
            klass.respond_to?(:table_name) && klass.table_name == table && !klass.abstract_class?
          end
        rescue StandardError
          nil
        end

        # Extracts the unquoted table name from the FROM / INTO / UPDATE
        # clause. Handles all three identifier-quote styles (PG/SQLite/
        # MySQL). Returns nil on unparseable SQL.
        def extract_table_name(sql)
          # DELETE FROM "table"
          if (m = sql.match(/\ADELETE FROM\s+["`]?([^"`\s]+)["`]?/i))
            return m[1]
          end
          # UPDATE "table"
          if (m = sql.match(/\AUPDATE\s+["`]?([^"`\s]+)["`]?/i))
            return m[1]
          end
          # INSERT INTO "table"
          if (m = sql.match(/\AINSERT INTO\s+["`]?([^"`\s]+)["`]?/i))
            return m[1]
          end

          nil
        end

        # Builds the source_data hash from the parser result, applying
        # encrypted_attributes drop + sensitive-pattern masking on
        # column-keyed values.
        def build_source_data(operation:, model_class:, row_count:, parse_result:)
          base = {
            model_class: model_class.name,
            operation: operation.to_s,
            row_count: row_count
          }

          return base if parse_result[:unparseable]

          if (set = parse_result[:set])
            base[:set] = mask_set_hash(set, model_class)
          end

          if (template = parse_result[:where_template])
            base[:where_template] = template
            base[:where_binds] = mask_where_binds(parse_result[:where_binds], model_class)
          end

          if (columns = parse_result[:columns])
            base[:columns] = filter_columns(columns, model_class)
          end

          base
        end

        # Walks `{ column => value }` from update_all SET, masking values
        # whose column is encrypted OR matches a sensitive pattern. Date /
        # Time / BigDecimal values get JSON-formatted so they don't collapse
        # to "[Object]" downstream.
        def mask_set_hash(set, model_class)
          set.each_with_object({}) do |(col, value), acc|
            acc[col] =
              if ::EzLogsAgent::EncryptedAttributes.attribute?(model_class, col)
                "[FILTERED]"
              elsif ::EzLogsAgent::SensitivePatterns.match?(col)
                "[FILTERED]"
              else
                format_value_for_json(value)
              end
          end
        end

        # Walks the array of {column:, value:} bind entries from the WHERE
        # parser, same masking rules as mask_set_hash. Binds whose column
        # is nil (the parser couldn't attribute them) ride through with
        # the formatted value — display falls back to template substitution.
        def mask_where_binds(binds, model_class)
          (binds || []).map do |bind|
            col = bind[:column]
            value = bind[:value]
            masked_value =
              if col && (::EzLogsAgent::EncryptedAttributes.attribute?(model_class, col) ||
                         ::EzLogsAgent::SensitivePatterns.match?(col))
                "[FILTERED]"
              else
                format_value_for_json(value)
              end

            { column: col, value: masked_value }
          end
        end

        # For insert_all / upsert_all, we ship column names ONLY (no
        # values — product decision). Sensitive column names still need
        # masking so the column LIST itself doesn't hint "this table has
        # a `password` column". Drop sensitive columns from the displayed
        # list; replace with the literal marker so the count remains true.
        def filter_columns(columns, model_class)
          columns.map do |col|
            if ::EzLogsAgent::EncryptedAttributes.attribute?(model_class, col)
              "[FILTERED]"
            elsif ::EzLogsAgent::SensitivePatterns.match?(col)
              "[FILTERED]"
            else
              col
            end
          end
        end

        # Builds the sentinel resource entry. row_count may be nil (Rails
        # < 7 didn't ship it; some adapters still don't) — fall back to
        # "bulk" so the entry is non-nil and the server-side
        # ResourceAggregationStage doesn't drop it.
        def build_resource_ids(model_class, row_count)
          count_str = row_count.is_a?(Integer) ? row_count.to_s : "unknown"
          [{ resource_type: model_class.name, resource_id: "bulk:#{count_str}" }]
        end

        # Mirrors DatabaseCapturer's same-named guard. capture_database = false
        # disables both capturers in one switch.
        def capture_enabled?
          ::EzLogsAgent.configuration.capture_database
        rescue StandardError
          false
        end

        # Uses DatabaseCapturer's existing all_excluded_tables list — one
        # config knob, both capturers obey it.
        def table_excluded?(model_class)
          return false unless model_class.respond_to?(:table_name)

          ::EzLogsAgent.configuration.all_excluded_tables.include?(model_class.table_name)
        rescue StandardError
          false
        end

        # Same formatter as DatabaseCapturer. Keeps Date / Time / BigDecimal
        # from collapsing to "[Object]" when they reach Sanitizer / wire.
        def format_value_for_json(value)
          case value
          when ::Time, ::DateTime
            value.iso8601
          when ::Date
            value.to_s
          when ::BigDecimal
            value.to_f
          when ::Array
            value.map { |v| format_value_for_json(v) }
          else
            value
          end
        end

        def safe_log_error(stage, exception)
          ::EzLogsAgent::Logger.error(
            "[BulkDatabaseCapturer] #{stage} failed: #{exception.class} - #{exception.message}"
          )
        rescue StandardError
          # Even logging can fail in pathological boot states. We've done
          # everything reasonable; drop the event silently.
          nil
        end
      end
    end
  end
end
