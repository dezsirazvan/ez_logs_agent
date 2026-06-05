# frozen_string_literal: true

module EzLogsAgent
  # Pure-functional parser for the four ActiveRecord bulk operations that
  # bypass per-row callbacks: delete_all, update_all, insert_all, upsert_all.
  # Used by BulkDatabaseCapturer to turn an AS::Notifications "sql.active_record"
  # payload into a structured wire shape the server can humanize.
  #
  # ## What it extracts
  #
  # For delete_all:
  #   { operation: :delete_all, where_template: "status = $1", where_binds: [{column:, value:}] }
  #
  # For update_all:
  #   { operation: :update_all, set: {"status" => "paid"}, where_template:, where_binds: }
  #
  # For insert_all / upsert_all:
  #   { operation: :insert_all|:upsert_all, columns: ["name", "email"] }
  #   (No values — per the product decision; column SHAPE only.)
  #
  # For anything else (subqueries, joins, raw SQL the regex can't parse,
  # malformed binds): returns { unparseable: true }. BulkDatabaseCapturer
  # falls back to shipping row_count + operation + model_class with no
  # template / binds / set — the timeline still reads "Bulk delete: 50,000
  # orders" minus the WHERE detail.
  #
  # ## Why regex (not Arel / pg_query)
  #
  # Both Arel and pg_query are adapter-specific and either slow or heavy
  # to add as a runtime dependency on every customer host app. Regex on
  # the standardized AR-emitted SQL string is fast (sub-millisecond on
  # typical statements) and adapter-tolerant. The graceful "unparseable"
  # branch covers the long tail.
  #
  # ## Adapter quoting handled
  #
  # - PostgreSQL: "orders"."status" = $1   (double-quoted, $N placeholders)
  # - SQLite:     "orders"."status" = ?     (double-quoted, ? placeholders)
  # - MySQL:      `orders`.`status` = ?     (backticks, ? placeholders)
  module BulkSqlParser
    # Loose match for an identifier wrapped in any of the three quote
    # styles AR uses. Captures the unquoted name.
    IDENTIFIER = /["`]([^"`]+)["`]/.freeze

    # Either a "qualified" or "bare" identifier reference, used in
    # WHERE/SET clause columns. AR prefixes the table name in some
    # paths and not in others — accept both. Captures just the column.
    COLUMN = /(?:#{IDENTIFIER}\.)?#{IDENTIFIER}/.freeze

    # A bind placeholder — Postgres uses $N (1-indexed), SQLite/MySQL use ?.
    # The order of placeholders in the SQL corresponds 1:1 with the order
    # of values in `binds` / `type_casted_binds`.
    PLACEHOLDER = /(?:\$\d+|\?)/.freeze

    module_function

    # @param sql [String] Raw SQL string from `payload[:sql]`.
    # @param type_casted_binds [Array] `payload[:type_casted_binds]` —
    #   already-typecast values in placeholder order. May be nil for
    #   raw SQL paths.
    # @return [Hash] Always returns a Hash. Either the parsed structure
    #   (keys above) or `{ unparseable: true }`.
    def parse(sql:, type_casted_binds:)
      return { unparseable: true } if sql.nil? || sql.empty?

      sql_stripped = strip_query_log_tags(sql.strip)

      case sql_stripped
      when /\ADELETE FROM /i
        parse_delete(sql_stripped, type_casted_binds || [])
      when /\AUPDATE /i
        parse_update(sql_stripped, type_casted_binds || [])
      when /\AINSERT INTO /i
        parse_insert(sql_stripped)
      else
        { unparseable: true }
      end
    rescue StandardError
      # If the regex engine, binds zipping, or any sub-parse step raises,
      # ship unparseable rather than crash the capture handler. The
      # BulkDatabaseCapturer's own rescue would also catch this, but
      # defending here means the rest of the capturer sees a uniform
      # return shape.
      { unparseable: true }
    end

    # Strip Rails 7+ Query Log Tags (`/*application='X',action='Y'*/`)
    # AND any other trailing SQL comments. They land at the end of every
    # statement when `config.active_record.query_log_tags_enabled = true`
    # and are pure noise on the timeline — they leak the host app's name
    # and controller into the user-visible filter line. Removing them at
    # parse time means we never ship them on the wire.
    def strip_query_log_tags(sql)
      sql.gsub(%r{/\*.*?\*/}m, "").rstrip
    end

    # Returns the symbolic operation name we expect downstream. Detected
    # from SQL shape, independent of the `payload[:name]` Rails version
    # variance (see plan §"insert_all/upsert_all payload :name varies").
    # Upsert detection requires the `ON CONFLICT` (PG) or `ON DUPLICATE KEY`
    # (MySQL) clause — bare INSERTs are insert_all.
    #
    # @return [Symbol, nil] :delete_all, :update_all, :insert_all,
    #   :upsert_all, or nil if not a bulk op.
    def detect_operation(sql)
      return nil if sql.nil?

      sql_up = sql.lstrip.upcase

      return :delete_all if sql_up.start_with?("DELETE FROM ")
      return :update_all if sql_up.start_with?("UPDATE ")

      if sql_up.start_with?("INSERT INTO ")
        # Disambiguate insert_all vs upsert_all:
      # - insert_all on PG/SQLite emits `ON CONFLICT DO NOTHING` (still insert).
      # - upsert_all on PG/SQLite emits `ON CONFLICT ... DO UPDATE SET ...`.
      # - upsert_all on MySQL emits `ON DUPLICATE KEY UPDATE ...`.
        if (sql_up.include?("ON CONFLICT") && sql_up.include?("DO UPDATE")) ||
           sql_up.include?("ON DUPLICATE KEY")
          return :upsert_all
        end

        :insert_all
      end
    end

    # --- DELETE FROM "orders" WHERE "orders"."status" = $1 ---
    def parse_delete(sql, type_casted_binds)
      where_sql = extract_where(sql)
      template, binds = build_template_and_binds(where_sql, type_casted_binds)

      { operation: :delete_all, where_template: template, where_binds: binds }
    end

    # --- UPDATE "orders" SET "status" = $1 WHERE "orders"."status" = $2 ---
    # SET binds come first in placeholder order, then WHERE binds.
    def parse_update(sql, type_casted_binds)
      set_sql = extract_set(sql)
      where_sql = extract_where(sql)
      return { unparseable: true } if set_sql.nil?

      set_pairs, set_bind_count = parse_set_assignments(set_sql)
      set_binds = type_casted_binds.first(set_bind_count)
      where_binds_raw = type_casted_binds.drop(set_bind_count)

      set_hash = zip_set_values(set_pairs, set_binds)
      where_template, where_binds = build_template_and_binds(where_sql, where_binds_raw)

      {
        operation: :update_all,
        set: set_hash,
        where_template: where_template,
        where_binds: where_binds
      }
    end

    # --- INSERT INTO "users" ("name","email") VALUES (...), (...) ---
    def parse_insert(sql)
      operation = detect_operation(sql)
      return { unparseable: true } unless operation == :insert_all || operation == :upsert_all

      columns = extract_insert_columns(sql)
      return { unparseable: true } if columns.nil? || columns.empty?

      { operation: operation, columns: columns }
    end

    # Returns the WHERE-clause SQL (without the keyword), or nil if absent.
    # Stops at end-of-string, RETURNING, ORDER BY, LIMIT (AR rarely emits
    # these on bulk DML but cheap insurance).
    def extract_where(sql)
      match = sql.match(/\sWHERE\s+(.+?)(?:\s+(?:RETURNING|ORDER BY|LIMIT)\b|\z)/i)
      match && match[1].strip
    end

    # Returns the SET-clause SQL between "SET" and "WHERE"/end-of-string.
    def extract_set(sql)
      match = sql.match(/\sSET\s+(.+?)(?:\s+WHERE\s+|\s+RETURNING\b|\z)/i)
      match && match[1].strip
    end

    # SET clause is comma-separated `"col" = <placeholder|literal>` pairs.
    # AR inlines non-symbol values as literals (no placeholder) — we still
    # surface those in the result so the reader sees what changed.
    # Returns [[col_name, placeholder_or_literal_str], ...] + total bind count.
    def parse_set_assignments(set_sql)
      pairs = []
      bind_count = 0

      split_top_level_commas(set_sql).each do |assignment|
        m = assignment.match(/\A#{COLUMN}\s*=\s*(.+)\z/)
        next unless m

        col = m[2] || m[1]
        rhs = m[3].strip
        pairs << [col, rhs]
        bind_count += 1 if rhs.match?(PLACEHOLDER)
      end

      [pairs, bind_count]
    end

    # Walks set_pairs in order, taking the next bind for each placeholder
    # RHS and pulling the literal text for non-placeholder RHS (e.g.,
    # `updated_at = '2026-06-05 12:00:00'`).
    def zip_set_values(set_pairs, set_binds)
      bind_idx = 0
      set_pairs.each_with_object({}) do |(col, rhs), acc|
        if rhs.match?(PLACEHOLDER)
          acc[col] = set_binds[bind_idx]
          bind_idx += 1
        else
          # Strip surrounding quotes to surface the actual value.
          acc[col] = rhs.gsub(/\A['"]|['"]\z/, "")
        end
      end
    end

    # Splits on commas that are NOT inside (parens) or quotes. Bulk DML
    # SET / WHERE almost never nests, but defensive against function
    # calls like `coalesce(x, 0)`.
    def split_top_level_commas(str)
      result = []
      depth = 0
      in_quote = false
      quote_char = nil
      buffer = +""

      str.each_char do |ch|
        if in_quote
          buffer << ch
          in_quote = false if ch == quote_char
        elsif ch == "'" || ch == '"' || ch == "`"
          in_quote = true
          quote_char = ch
          buffer << ch
        elsif ch == "("
          depth += 1
          buffer << ch
        elsif ch == ")"
          depth -= 1
          buffer << ch
        elsif ch == "," && depth.zero?
          result << buffer.strip unless buffer.empty?
          buffer = +""
        else
          buffer << ch
        end
      end
      result << buffer.strip unless buffer.empty?
      result
    end

    # Given a WHERE clause SQL and the binds in placeholder order, walk
    # the placeholders and pair each one with the column to its LEFT
    # (the standard `"table"."col" = $1` shape AR emits). Returns the
    # template (placeholder-preserved) and the binds tagged with column.
    #
    # Unrecognized shapes (subselects, joins, NULL checks without binds)
    # leave the template intact but produce no column for the bind, in
    # which case the bind ships with column: nil. The display layer
    # handles nil-column binds.
    def build_template_and_binds(where_sql, type_casted_binds)
      return [nil, []] if where_sql.nil?

      template = where_sql
      binds = []
      bind_index = 0

      # Walk the template scanning each placeholder, looking backward
      # for the nearest column identifier to its left.
      template.scan(PLACEHOLDER) do
        match_data = Regexp.last_match
        next unless match_data

        column = nearest_column_left_of(template, match_data.begin(0))
        value = type_casted_binds[bind_index]
        binds << { column: column, value: value }
        bind_index += 1
      end

      [template, binds]
    end

    # Finds the most recent column identifier to the left of `pos` in
    # the WHERE clause. Used to attribute each bind to its column name
    # so we can mask sensitive values by name downstream.
    def nearest_column_left_of(where_sql, pos)
      prefix = where_sql[0...pos]
      # Look for the last identifier before the operator (=, <, >, etc.)
      match = prefix.match(/#{COLUMN}\s*(?:=|<>|!=|<=|>=|<|>|LIKE|IN|IS)\s*\z/i)
      return nil unless match

      # COLUMN has two capture groups: [table, col] or [_, col].
      match[2] || match[1]
    end

    # --- INSERT INTO "users" ("name","email") VALUES ...  ---
    # Extracts the ordered column list. Returns nil if the open paren
    # column list isn't present (e.g., INSERT ... DEFAULT VALUES).
    def extract_insert_columns(sql)
      # First parenthesized list after the table name.
      m = sql.match(/\AINSERT INTO\s+#{IDENTIFIER}\s*\(([^)]+)\)/i)
      return nil unless m

      columns_block = m[2]
      columns_block.split(",").map do |col|
        col.strip.gsub(/\A["`]|["`]\z/, "")
      end.reject(&:empty?)
    end
  end
end
