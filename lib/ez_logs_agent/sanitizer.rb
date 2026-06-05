# frozen_string_literal: true

module EzLogsAgent
  # Canonical sanitizer for "user-supplied data we're about to ship over
  # the wire": HTTP params, GraphQL variables, and ActiveJob/Sidekiq
  # arguments.
  #
  # Rules:
  # - Sensitive keys (password / token / secret / api_key / credit_card,
  #   plus user-configured patterns) are replaced with "[FILTERED]".
  # - Nested objects recurse up to MAX_NESTING_DEPTH (3); anything deeper
  #   collapses to "[Object]" so we never serialize unbounded graphs.
  # - Arrays: small primitive arrays pass through; large ones (>5)
  #   collapse to a preview-plus-count string; arrays of objects are
  #   sanitized element-by-element with the same depth budget.
  # - Non-primitive Ruby objects (anything not String/Numeric/Bool/nil)
  #   become "[Object]". This protects us from accidentally serializing
  #   ActiveRecord instances or other big graphs that found their way
  #   into a job argument.
  #
  # The module is pure (no I/O, no state), so it's safe to call from
  # any thread.
  module Sanitizer
    # Default sensitive-key patterns. Matched case-insensitively as
    # SUBSTRINGS of the key, so `customer_password` matches `password`.
    SENSITIVE_PATTERNS = %w[
      password passwd pwd
      token access_token refresh_token api_token auth_token
      secret api_secret client_secret
      api_key apikey private_key privatekey secret_key secretkey
      credential auth authorization
      encrypted encrypted_data
      ssn social_security
      credit_card card_number cvv cvc
    ].freeze

    # Hard ceiling for nested object recursion. Deeper structures
    # collapse to the literal string "[Object]".
    MAX_NESTING_DEPTH = 3

    # Threshold above which an array is summarized instead of inlined.
    # Below this size, primitive arrays are shipped verbatim; arrays
    # of objects are mapped element-by-element.
    MAX_ARRAY_DISPLAY_SIZE = 5

    class << self
      # Sanitize a single key/value pair. Public entry point used by
      # HTTP-param and job-arg sanitization.
      #
      # @param key [String, Symbol] Variable / parameter name.
      # @param value [Object] Variable / parameter value.
      # @param depth [Integer] Current recursion depth.
      # @return [Object] Sanitized value (may be the original primitive).
      def sanitize_value(key, value, depth = 0)
        return "[FILTERED]" if sensitive_key?(key)
        return sanitize_nested_object(value, depth) if value.is_a?(Hash)
        return sanitize_array_value(value, depth) if value.is_a?(Array)
        return value if primitive?(value)

        # Anything else (AR records, dates, custom objects) collapses to
        # a placeholder so we never accidentally serialize a huge graph.
        "[Object]"
      end

      # Sanitize an ordered list of job arguments (positional). Returns
      # an Array with each element sanitized as if its index were the
      # key (no sensitive-key match for integers — only the nested
      # structure matters at the top level).
      #
      # @param args [Array] Job arguments array.
      # @return [Array] Sanitized arguments array.
      def sanitize_args(args)
        return [] unless args.is_a?(Array)

        # Top-level array uses the same array-rules so giant arg lists
        # truncate to a preview-with-count rather than ship verbatim.
        sanitize_array_value(args, 0)
      end

      # Check whether a key matches a sensitive pattern. Public so the
      # HTTP middleware can short-circuit early on identical keys.
      #
      # @param key [String, Symbol]
      # @return [Boolean]
      def sensitive_key?(key)
        key_lower = key.to_s.downcase
        return true if SENSITIVE_PATTERNS.any? { |pattern| key_lower.include?(pattern) }

        user_patterns = EzLogsAgent.configuration.excluded_graphql_variable_keys || []
        user_patterns.any? { |pattern| key_lower.include?(pattern.to_s.downcase) }
      rescue
        # Defensive: when in doubt, treat as sensitive.
        true
      end

      private

      def sanitize_nested_object(hash, depth)
        # ActiveJob serializes record refs as `{"_aj_globalid" => "gid://..."}`.
        # Preserve these even past the depth limit so a record reference
        # survives the [Object] collapse and the server can display WHICH
        # record the job ran on. Display formatting (gid → "User #42") is
        # the server's job; the agent's job is to keep the data on the wire.
        return hash if global_id_hash?(hash)

        # ActiveJob wraps keyword args at TWO layers: the outer mailer
        # payload `{"args" => [kwargs_hash], "_aj_ruby2_keywords" => ["args"]}`
        # and the inner kwargs hash itself, also tagged `_aj_ruby2_keywords`.
        # Each wrapper layer is framework noise — recursing into it without
        # spending depth budget keeps the real kwargs from collapsing to
        # "[Object]" at depth 3. Sensitive-key filtering still runs on the
        # real entries (passwords don't leak; the wrapper just doesn't cost
        # a depth level).
        return sanitize_ruby2_keywords_wrapper(hash, depth) if ruby2_keywords_wrapper?(hash)

        return "[Object]" if depth >= MAX_NESTING_DEPTH
        return {} if hash.empty?

        hash.each_with_object({}) do |(key, value), result|
          result[key] = sanitize_value(key, value, depth + 1)
        end
      end

      # Sanitize the entries of an _aj_ruby2_keywords wrapper at the SAME
      # depth as the wrapper itself, then re-attach the marker. This is what
      # lets kwargs survive past the depth-3 cap when they're wrapped at
      # depth 2-3 by the outer mailer payload.
      def sanitize_ruby2_keywords_wrapper(hash, depth)
        result = {}
        hash.each do |key, value|
          if ruby2_keywords_marker_key?(key)
            # Preserve the marker verbatim — it's used to identify the
            # wrapper on the receiving side, not to display.
            result[key] = value
          else
            result[key] = sanitize_value(key, value, depth)
          end
        end
        result
      end

      def sanitize_array_value(array, depth)
        return [] if array.empty?

        all_primitives = array.all? { |item| primitive?(item) }

        if all_primitives
          if array.size <= MAX_ARRAY_DISPLAY_SIZE
            array
          else
            preview = array.first(MAX_ARRAY_DISPLAY_SIZE)
            "#{preview}... (#{array.size} total)"
          end
        else
          if array.size <= MAX_ARRAY_DISPLAY_SIZE
            array.map { |item| sanitize_array_item(item, depth) }
          else
            preview = array.first(MAX_ARRAY_DISPLAY_SIZE).map { |item| sanitize_array_item(item, depth) }
            { "_truncated" => true, "_count" => array.size, "_preview" => preview }
          end
        end
      end

      def sanitize_array_item(item, depth)
        if primitive?(item)
          item
        elsif item.is_a?(Hash)
          sanitize_nested_object(item, depth + 1)
        elsif item.is_a?(Array)
          sanitize_array_value(item, depth + 1)
        else
          "[Object]"
        end
      end

      def primitive?(value)
        value.nil? ||
          value.is_a?(String) ||
          value.is_a?(Numeric) ||
          value.is_a?(TrueClass) ||
          value.is_a?(FalseClass)
      end

      # True iff `hash` is the exact one-key shape ActiveJob uses to serialize
      # an ActiveRecord (or any GlobalID::Identification) argument:
      # `{"_aj_globalid" => "gid://..."}`. Used to exempt these hashes from
      # the depth-limit collapse so the wire still carries the record ref.
      def global_id_hash?(hash)
        return false unless hash.is_a?(Hash) && hash.size == 1
        gid = hash["_aj_globalid"] || hash[:_aj_globalid]
        gid.is_a?(String) && gid.start_with?("gid://")
      end

      # True iff `hash` carries the `_aj_ruby2_keywords` marker. ActiveJob
      # uses this marker on any hash that originated as a keyword-argument
      # splat (so the framework can re-splat on deserialize). Used to skip
      # the depth penalty for these framework wrappers — the marker's
      # presence is the unambiguous signal we're inside an ActiveJob
      # serialization layer, not customer data.
      def ruby2_keywords_wrapper?(hash)
        return false unless hash.is_a?(Hash)
        hash.key?("_aj_ruby2_keywords") || hash.key?(:_aj_ruby2_keywords)
      end

      def ruby2_keywords_marker_key?(key)
        key.to_s == "_aj_ruby2_keywords"
      end
    end
  end
end
