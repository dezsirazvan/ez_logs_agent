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

          # Cache configuration values that the hot path checks per
          # notification. Re-read on every install (specs reinstall
          # after toggling config). Runtime mutations to these settings
          # require uninstall! + install to take effect — acceptable
          # because nobody flips this at runtime in production.
          @capture_enabled =
            begin
              ::EzLogsAgent.configuration.capture_database
            rescue StandardError
              false
            end
          @excluded_tables =
            begin
              ::EzLogsAgent.configuration.all_excluded_tables.dup.freeze
            rescue StandardError
              [].freeze
            end

          install_row_count_capture!

          # 5-arity block bypasses the `*args` splat allocation per
          # notification — measurable on hot paths where we ignore
          # ~99% of events. Block accepts positional args matching the
          # AS::N convention: (name, start, finish, id, payload).
          @subscriber = ::ActiveSupport::Notifications.subscribe("sql.active_record") do |name, started, finished, _id, payload|
            handle_notification(name, started, finished, payload)
          end
          @installed = true
        end

        # Patches ActiveRecord::Relation's bulk methods to backfill the
        # affected-row count on the most recently captured bulk_database
        # event. See the comment on RelationRowCountStash below for why
        # this is necessary (Rails' payload[:row_count] is unreliable
        # for plain DELETE/UPDATE on PG).
        def install_row_count_capture!
          return if @relation_patched
          return unless defined?(::ActiveRecord::Relation)

          ::ActiveRecord::Relation.prepend(RelationRowCountStash)
          @relation_patched = true
        rescue StandardError => e
          # Patching is best-effort — if AR's Relation isn't there or the
          # prepend raises, the capturer still works with payload[:row_count].
          ::EzLogsAgent::Logger.debug("[BulkDatabaseCapturer] could not patch Relation: #{e.class}: #{e.message}")
        end

        # Patches the row_count on the most recently buffered bulk_database
        # event when its model matches `model_class`. Called from the
        # RelationRowCountStash module immediately after `super` returns
        # from delete_all / update_all. The buffer's `peek_last` API is
        # the lightweight read path; we mutate in place because the
        # event hash hasn't been serialized yet.
        def backfill_row_count(real_count, model_class)
          return if real_count.nil?

          tail = ::EzLogsAgent::Buffer.peek_last
          return unless tail.is_a?(Hash)
          return unless tail[:source_type] == "bulk_database"
          return unless tail.dig(:source_data, :model_class) == model_class.name

          tail[:source_data][:row_count] = real_count
          if (rids = tail[:resource_ids]).is_a?(Array) && rids.first.is_a?(Hash)
            rids.first[:resource_id] = "bulk:#{real_count}"
          end
        rescue StandardError => e
          ::EzLogsAgent::Logger.debug("[BulkDatabaseCapturer] backfill_row_count failed: #{e.class}: #{e.message}")
        end
      end

      # Backfills the affected-row count on the most recently captured
      # bulk_database event. Order of operations:
      #
      #   1. Customer calls Relation#delete_all (or update_all).
      #   2. AR runs the SQL → sql.active_record fires → our AS::N
      #      handler captures the event with row_count=payload[:row_count]
      #      (often 0 on PG for plain DELETE).
      #   3. delete_all's super returns the affected count to us.
      #   4. We patch the most-recently-buffered bulk_database event's
      #      source_data[:row_count] AND its sentinel resource_id so the
      #      timeline shows the real number.
      #
      # This is a thin shim — only the count is touched, never the SQL,
      # context, or wire shape. If the buffer's tail isn't a bulk_database
      # event for our model (e.g. AS::N skipped it), we leave it alone.
      module RelationRowCountStash
        def delete_all
          result = super
          ::EzLogsAgent::Capturers::BulkDatabaseCapturer.backfill_row_count(result, klass) if result.is_a?(Integer)
          result
        end

        def update_all(*args, **kwargs, &block)
          result = super
          ::EzLogsAgent::Capturers::BulkDatabaseCapturer.backfill_row_count(result, klass) if result.is_a?(Integer)
          result
        end
      end

      class << self

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
          # Hot path: this runs once per SQL statement in the host app —
          # often thousands of times per second on a busy tenant. EVERY
          # branch above the cheapest filter has to be fast. Order is:
          #
          #   1. Cheapest possible name check (string suffix, no regex,
          #      no method dispatch on the configuration object). This
          #      rejects ~99% of notifications in <1 µs.
          #   2. Then capture_enabled? (config check).
          #   3. Then everything else.
          # Cheapest possible early-exit: a single instance-variable
          # read. This branch fires on EVERY SQL statement in the host
          # app and must not allocate or call into configuration.
          return unless @capture_enabled
          return unless payload.is_a?(Hash)
          name = payload[:name]
          return unless name && name_eligible?(name)

          operation = ::EzLogsAgent::BulkSqlParser.detect_operation(payload[:sql])
          return unless operation

          model_class = resolve_model_class(payload[:sql])
          return if model_class.nil?
          return if table_excluded?(model_class)

          parse_result = ::EzLogsAgent::BulkSqlParser.parse(
            sql: payload[:sql],
            type_casted_binds: payload[:type_casted_binds]
          )

          # Drop Rails framework rewrites that aren't real business activity:
          #
          #   * Foreign-key nullification — when a parent has `dependent:
          #     :restrict_with_error` AND the child's `belongs_to :parent`
          #     is `optional: true`, Rails rewrites `child.delete_all`
          #     into `UPDATE children SET parent_id = NULL WHERE ...`
          #     before the destroy. There is no business meaning here;
          #     it's framework cleanup before the parent goes away.
          #
          #   * Counter-cache / increment! — `Model.increment_counter(:x)`
          #     and `record.increment!(:x)` compile to
          #     `UPDATE ... SET x = COALESCE(x, 0) + N WHERE id = ?`,
          #     which is Rails plumbing for a numeric counter bump, not
          #     a user-visible change.
          #
          # Both produce high-volume noise on the timeline (see EZLogs's
          # own dogfood where Company#increment_actions_count! fires
          # per ingest batch). Filtering at the capturer means they
          # don't ride the wire at all.
          return if framework_rewrite?(operation, parse_result)

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
          name = payload[:name]
          name.is_a?(String) && name_eligible?(name)
        end

        # Cheapest possible bulk-name check — string `end_with?` calls,
        # no regex compilation, no method dispatch. Runs on the hot path.
        # The four shapes we care about (per AR convention):
        #   "<Model> Delete All", "<Model> Update All",
        #   "<Model> Insert", "<Model> Upsert"
        # (Older Rails 7 also used " Bulk Insert" / " Bulk Upsert" — those
        # still end with "Insert"/"Upsert" so end_with? catches them.)
        # Per-row CRUD names like "<Model> Create", "<Model> Update",
        # "<Model> Destroy" fail all four suffix checks and bail in <1 µs.
        def name_eligible?(name)
          name.end_with?(" All") || name.end_with?(" Insert") || name.end_with?(" Upsert")
        end

        # Looks up the model class from the SQL's table name. Returns nil
        # for SQL we can't attribute (raw multi-table queries, anonymous
        # adapter SQL, schema introspection). Skipping these is correct —
        # we'd have nothing to display anyway.
        def resolve_model_class(sql)
          return nil if sql.nil?

          table = extract_table_name(sql)
          return nil if table.nil?

          # Try the descendants list first — cheap and works in environments
          # where models are already eager-loaded (production, Sidekiq workers).
          loaded = ::ActiveRecord::Base.descendants.find do |klass|
            klass.respond_to?(:table_name) && klass.table_name == table && !klass.abstract_class?
          end
          return loaded if loaded

          # Fallback for development mode and any lazy-autoload path: derive
          # the model class name from the table name via Rails' inflector
          # and try to safe_constantize it. ActiveRecord's reflection class
          # caches it on first call, so subsequent bulk ops on the same
          # table hit the descendants path above.
          constant_name = table.to_s.classify
          klass = constant_name.safe_constantize
          return klass if klass.is_a?(Class) &&
                          klass < ::ActiveRecord::Base &&
                          klass.respond_to?(:table_name) &&
                          klass.table_name == table

          nil
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
        # < 7 didn't ship it; some adapters still don't), and 0 is also
        # not informative (PG's update_all returns 0 in some paths) —
        # fall back to "many" so the display reads naturally and the
        # server-side ResourceAggregationStage doesn't drop it.
        def build_resource_ids(model_class, row_count)
          count_str = (row_count.is_a?(Integer) && row_count > 0) ? row_count.to_s : "many"
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
        # config knob, both capturers obey it. The list is memoized at
        # install time (`@excluded_tables`) so we don't pay a Hash
        # method dispatch on every captured event. Customers who change
        # config at runtime need to call uninstall! + install — the same
        # constraint that already applies to `capture_database`.
        def table_excluded?(model_class)
          return false unless model_class.respond_to?(:table_name)

          @excluded_tables.include?(model_class.table_name)
        rescue StandardError
          false
        end

        # Detects Rails-generated update_all SQL that we can't render
        # meaningfully OR that is pure framework noise. We are deliberately
        # narrow here — anything that COULD be a real change a customer
        # cares about (even SET col = NULL on N rows) we keep.
        #
        # Filtered shapes:
        #
        #   1. Empty SET hash — the parser couldn't extract any column →
        #      value pairs (e.g. unquoted column names in raw SQL). The
        #      captured event would render with no "Set X to Y" detail
        #      and no humanized filter, just "Updated 26 things" with an
        #      empty Operation block. That's misleading.
        #
        #   2. Counter cache / increment! / decrement! — any SET value is
        #      a `COALESCE(<col>, 0) + N` expression. Rails uses this
        #      shape for `increment_counter`, `increment!`,
        #      `update_counters`. The semantics are "bump a number by N",
        #      which is plumbing-grade noise: high volume (per-request
        #      counter bumps fire dozens of times per minute on a busy
        #      tenant) and zero business meaning to a non-technical
        #      reader. On the EZLogs server alone these would dominate
        #      the timeline.
        #
        # SET <fk> = NULL on N rows IS captured — even though Rails sometimes
        # generates it implicitly as cleanup before a destroy, it's also
        # the shape of a real customer-issued nullification (soft-orphaning,
        # disassociating tags from an item, etc.), and from the SQL alone
        # we can't tell the two apart. Showing it honestly is the right call:
        # the reader sees that N rows had their column X set to NULL.
        #
        # @return [Boolean]
        def framework_rewrite?(operation, parse_result)
          return false unless operation == :update_all
          return false unless parse_result.is_a?(Hash)

          set = parse_result[:set]

          # Empty SET hash: parser bailed. Drop — would render as an
          # empty Operation block.
          return true if set.is_a?(Hash) && set.empty? && !parse_result[:unparseable]

          return false unless set.is_a?(Hash) && set.any?

          # Counter-cache / increment! — any value contains COALESCE().
          # Distinct from a deliberate UPDATE because the SET expression
          # references the column on its own RHS, which no business
          # update_all ever does.
          return true if set.values.any? { |v| v.to_s.include?("COALESCE(") }

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
