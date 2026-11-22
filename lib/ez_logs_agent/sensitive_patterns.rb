# frozen_string_literal: true

module EzLogsAgent
  # Single source of truth for the agent's sensitive-key denylist. Used by
  # every capture path that needs to mask a value based on its column /
  # parameter / argument name (Sanitizer for HTTP params + job args,
  # DatabaseCapturer for AR attributes, BulkDatabaseCapturer for SQL
  # WHERE binds + SET values).
  #
  # This is a NAME-pattern denylist — the secondary defense, separate from
  # the primary defense (Rails `encrypts :foo` introspection via
  # `model.class.encrypted_attributes`, handled in EncryptedAttributes).
  # Use both together: the encrypts check catches what the host app
  # declared, this list catches what got past the declaration (legacy
  # columns, manual hashing, externally-generated material).
  #
  # Matching rules:
  # - Case-insensitive
  # - Substring (so `customer_password` matches `password`)
  # - User-extensible via `EzLogsAgent.configuration.excluded_graphql_variable_keys`
  module SensitivePatterns
    # Union of every column / key name we treat as sensitive. Curated
    # from RFC 7468 / OWASP top sensitive-data categories plus
    # ActiveRecord conventions. Keep this list narrow but defensive —
    # adding a pattern is cheap; removing one is a backwards-incompatible
    # behavior change for customer data on the wire.
    PATTERNS = %w[
      password passwd pwd
      token access_token refresh_token api_token auth_token
      secret api_secret client_secret
      api_key apikey private_key privatekey secret_key secretkey
      public_key signing_key
      credential auth authorization
      encrypted encrypted_data
      pem cipher nonce salt digest signature hmac
      ssn social_security
      credit_card card_number cvv cvc
      passcode cardnumber
      verification_code recovery_code backup_code one_time_code login_code
    ].freeze

    # Short secret names matched only as a WHOLE word of the key (split on non-letters and
    # camelCase), so `pin` matches `pin`, `pinCode`, `mdm_unlock_pin` but never `shipping`.
    # Same list as the Next.js agent's SENSITIVE_WORD_PATTERNS.
    WORD_PATTERNS = %w[pin otp totp iban mfa passphrase jti].freeze

    module_function

    # @param key [String, Symbol, nil]
    # @return [Boolean] true if the key matches a sensitive pattern OR
    #   matches a user-configured pattern in `excluded_graphql_variable_keys`
    def match?(key)
      return false if key.nil?

      key_lower = key.to_s.downcase
      words = key.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase.split(/[^a-z0-9]+/)
      return true if WORD_PATTERNS.intersect?(words)

      # Substring patterns, on the key as written and on its words joined with "_" (so `apiKey`
      # and `api-key` match `api_key` too): only ever more matches than the key alone.
      joined = words.join("_")
      return true if PATTERNS.any? { |pattern| key_lower.include?(pattern) || joined.include?(pattern) }

      user_patterns = user_patterns_cache
      user_patterns.any? { |pattern| key_lower.include?(pattern) || joined.include?(pattern) }
    rescue StandardError
      # Defensive: if configuration access raises, treat as sensitive.
      # Better to over-mask than to leak.
      true
    end

    # Memoized lookup of user-configured patterns, already lowercased.
    # Called per HTTP param, per DB attribute, per job arg key. Without
    # the cache it would dispatch into EzLogsAgent.configuration on
    # every check.
    #
    # The cache is keyed by `object_id` of the configured array, so
    # `EzLogsAgent.configure { |c| c.excluded_graphql_variable_keys = [...] }`
    # invalidates it naturally (assigning a new array changes its id).
    # No explicit invalidation needed.
    def user_patterns_cache
      configured = EzLogsAgent.configuration.excluded_graphql_variable_keys
      return @cached_user_patterns if configured.nil? && @cached_source_id.nil?

      source_id = configured&.object_id
      if source_id != @cached_source_id
        @cached_user_patterns =
          (configured || []).map { |p| p.to_s.downcase }.freeze
        @cached_source_id = source_id
      end
      @cached_user_patterns
    end
    private_class_method :user_patterns_cache
  end
end
