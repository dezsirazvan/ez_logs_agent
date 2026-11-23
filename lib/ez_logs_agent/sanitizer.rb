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
    # Sensitive-key pattern list. Delegates to SensitivePatterns (single
    # source of truth shared with DatabaseCapturer / BulkDatabaseCapturer).
    # Kept as a constant alias for backwards compatibility — code that
    # used `Sanitizer::SENSITIVE_PATTERNS` continues to work.
    SENSITIVE_PATTERNS = EzLogsAgent::SensitivePatterns::PATTERNS

    # Hard ceiling for nested object recursion. Deeper structures
    # collapse to the literal string "[Object]".
    MAX_NESTING_DEPTH = 3

    # Threshold above which an array is summarized instead of inlined.
    # Below this size, primitive arrays are shipped verbatim; arrays
    # of objects are mapped element-by-element.
    MAX_ARRAY_DISPLAY_SIZE = 5

    # Value-shape masking: keys miss a secret written inside a value (a reset link in a job's
    # arguments, a token in an error message). The server's EventIngest::SensitiveFieldRedactor
    # applies the same rules at ingest; ezlogs-nextjs mirrors them. Shared test vectors:
    # spec/fixtures/secret_text_vectors.json. Every rule is linear in the input's length.
    #
    # Whitespace is spelled out (Ruby's \s is ASCII only, JavaScript's is Unicode) so both agents
    # read NBSP and other Unicode spaces the same way.
    WS = " \t\n\r\f\v\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF"
    URL_STOP = "#{WS}\"'<>\\\\`"
    # A URL keeps its scheme, host and path; its "user:pass@" and everything from "?" or "#" go.
    URL = Regexp.new("([A-Za-z][A-Za-z0-9+.-]{0,30}://)(?:[^#{URL_STOP}/?#]*@)?([^#{URL_STOP}?#]*)(?:[?#][^#{URL_STOP}]*)?")
    # The same written URL-encoded ("https%3A%2F%2Fapp%2Freset%3Ftoken%3D…"), any case.
    ENCODED_URL = Regexp.new(
      "([A-Za-z][A-Za-z0-9+.-]{0,30}%3A%2F%2F)(?:(?:(?!%40|%2F|%3F|%23)[^#{URL_STOP}/?#])*%40)?" \
      "((?:(?!%3F|%23)[^#{URL_STOP}?#])*)(?:(?:%3F|%23)[^#{URL_STOP}]*)?", Regexp::IGNORECASE
    )
    ENCODED_SCHEME = /%3A%2F%2F/i
    # A whole value that is a path ("/reset/…?token=…", "//cdn/x?sig=…"): its query and fragment go.
    RELATIVE_PATH = Regexp.new("\\A/[^#{WS}]*\\z")
    # A path segment that looks generated: 16+ characters with a lowercase letter, an uppercase
    # letter and a digit, never a file name with a "." (webhook and reset tokens; some random ids too), or a Telegram bot token.
    TOKEN_SEGMENT = /\A(?:bot\d+:[A-Za-z0-9_-]+|(?=[^a-z]*+[a-z])(?=[^A-Z]*+[A-Z])(?=\D*+\d)(?![^.]*+\.).{16,})\z/m
    SEGMENT_SPLIT = %r{(/|%2F)}i
    SECRET_START = "(?<![A-Za-z0-9])"
    SECRET_TEXT_PATTERNS = [
      # A private key: its body ends at the next "-----" (the END line), or at the end of the text.
      /-----BEGIN [A-Z ]{0,40}PRIVATE KEY-----[^-]*+(?:-(?!----)[^-]*+)*+(?:-----END [A-Z ]{0,40}PRIVATE KEY-----)?/,
      /#{SECRET_START}(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]++/,
      %r{#{SECRET_START}whsec_[A-Za-z0-9+/=]{8,}+},
      /#{SECRET_START}gh[pousr]_[A-Za-z0-9]{20,}+/,
      /#{SECRET_START}xox[abposr]-[A-Za-z0-9-]++/,
      /#{SECRET_START}(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])/
    ].freeze
    # Runs judged whole (jwt?, an OpenAI-style key): a match never rescans its own text.
    JWT_RUN = /#{SECRET_START}eyJ[\w-]*+(?:\.[\w-]*+)*+/
    SK_RUN = /#{SECRET_START}sk-[A-Za-z0-9_-]*+/
    # A word after "Bearer" or "Basic", judged by credential? (never "Basic Monthly", "Bearer of bad news").
    AUTH_CREDENTIAL = Regexp.new("#{SECRET_START}(Bearer|Basic)[#{WS}]++([\\w.~+/=-]+)", Regexp::IGNORECASE)
    CARD_NUMBER = /(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)/
    MASK = "[FILTERED]"

    # A mailer job whose method has a secret word (Devise's "reset_password_instructions",
    # "confirmation_instructions", "unlock_instructions"): its positional strings are masked (the token
    # Devise passes), except method names, GlobalIDs, numbers and UUIDs. Only ActionMailer's own shape
    # (mailer class, method, deliver_now/deliver_later): an ordinary job's "card_declined" stays. Same
    # words as the server's secret Server Action names.
    SECRET_ACTION_WORDS = %w[
      pin otp code verify mfa 2fa cvv cvc card password passwd secret token
      sign signin login reset credential credentials unlock confirmation invitation
    ].freeze
    METHOD_NAME = /\A[a-z]+(?:_[a-z]+)+\z/
    # ActionMailer's job arguments: the mailer class, its method, then "deliver_now" / "deliver_later".
    MAILER_CLASS = /\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*\z/
    MAILER_METHOD = /\A[a-z_][a-z0-9_]*\z/
    DELIVERY = /\Adeliver_(?:now|later)!?\z/
    KEPT_CALL_ARG = %r{\A(?:gid://|\d{1,20}\z|\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z)}

    class << self
      # A string with every secret-shaped part masked and every URL cut to scheme, host and path
      # (token-like path segments masked); anything else as is.
      # segments: false for the event's own request or outbound `path` (titles read its ids; a token in
      # a route is a known limit until agents send the route pattern).
      def scrub_text(value, segments: true)
        return value unless value.is_a?(String)

        cut = segments ? method(:mask_segments) : :itself.to_proc
        out = value
        out = out.gsub(URL) { "#{Regexp.last_match(1)}#{cut.call(Regexp.last_match(2))}" } if out.include?("://")
        out = out.gsub(ENCODED_URL) { "#{Regexp.last_match(1)}#{cut.call(Regexp.last_match(2))}" } if out.match?(ENCODED_SCHEME)
        out = cut.call(out[/\A[^?#]*/]) if out.match?(RELATIVE_PATH)
        out = SECRET_TEXT_PATTERNS.reduce(out) { |text, pattern| text.gsub(pattern, MASK) }
        out = out.gsub(JWT_RUN) { |run| jwt?(run) ? MASK : run }
        out = out.gsub(SK_RUN) { |run| run.length >= 19 && run.match?(/\d/) ? MASK : run }
        out = out.gsub(AUTH_CREDENTIAL) do
          match = Regexp.last_match
          credential?(match[1], match[2]) ? "#{match[1]} #{MASK}" : match[0]
        end
        out.gsub(CARD_NUMBER) do |match|
          digits = match.delete(" -")
          [15, 16].include?(digits.length) && luhn?(digits) ? MASK : match
        end
      rescue StandardError # an invalid byte sequence: fail closed
        MASK
      end

      # A secret mailer job's arguments with their positional strings masked (see MAILER_CLASS).
      def mask_secret_call_args(args)
        return args unless secret_mailer_call?(args)

        args.each_with_index.map { |arg, i| i > 2 ? mask_call_arg(arg) : arg }
      end

      def secret_mailer_call?(args)
        args.is_a?(Array) && args.size > 3 && args[0..2].all?(String) && args[0].match?(MAILER_CLASS) &&
          args[1].match?(MAILER_METHOD) && args[2].match?(DELIVERY) && secret_name?(args[1])
      end

      # A hash key masked like a value; two keys masked alike both stay ("[FILTERED]", "[FILTERED] 2").
      def unique_key(taken, key)
        return key unless taken.key?(key)

        n = 2
        n += 1 while taken.key?("#{key} #{n}")
        "#{key} #{n}"
      end

      def mask_segments(path)
        path.split(SEGMENT_SPLIT, -1).map { |part| part.match?(TOKEN_SEGMENT) ? MASK : part }.join
      end

      # "eyJ…" then dots: a header, a payload, then a signature or a payload of 16+.
      def jwt?(run)
        parts = run.split(".", -1)
        parts.size >= 2 && parts[0].length > 3 && !parts[1].empty? && (parts.size >= 3 || parts[1].length >= 16)
      end

      # A credential has a digit or symbol, or a lower-then-upper letter pair (base64), or 16+
      # characters; after "Basic" also 8+ characters ("Basic 2", "Basic Membership" are plan names).
      def credential?(scheme, token)
        shaped = token.match?(%r{[\d._~+/=-]}) || token.match?(/[a-z][A-Z]/)
        return shaped || token.length >= 16 if scheme.casecmp?("bearer")

        token.length >= 16 || (shaped && token.length >= 8)
      end

      def luhn?(digits)
        sum = digits.reverse.chars.each_with_index.sum do |c, i|
          d = c.to_i
          d *= 2 if i.odd?
          d > 9 ? d - 9 : d
        end
        (sum % 10).zero?
      end

      def secret_name?(name)
        words = name.split("_")
        ((words + words.each_cons(2).map(&:join)) & SECRET_ACTION_WORDS).any?
      end

      def mask_call_arg(arg)
        case arg
        when String then arg.match?(METHOD_NAME) || arg.match?(KEPT_CALL_ARG) ? arg : MASK
        when Array then arg.map { |item| mask_call_arg(item) }
        when Hash then arg.to_h { |key, value| [key, key.to_s == "args" ? mask_call_arg(value) : value] }
        else arg
        end
      end

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
        sanitize_array_value(mask_secret_call_args(args), 0)
      end

      # Check whether a key matches a sensitive pattern. Public so the
      # HTTP middleware can short-circuit early on identical keys.
      # Delegates to SensitivePatterns (single source of truth — also
      # consulted by DatabaseCapturer and BulkDatabaseCapturer).
      #
      # @param key [String, Symbol]
      # @return [Boolean]
      def sensitive_key?(key)
        EzLogsAgent::SensitivePatterns.match?(key)
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
