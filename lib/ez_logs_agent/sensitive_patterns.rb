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
    ].freeze

    module_function

    # @param key [String, Symbol, nil]
    # @return [Boolean] true if the key matches a sensitive pattern OR
    #   matches a user-configured pattern in `excluded_graphql_variable_keys`
    def match?(key)
      return false if key.nil?

      key_lower = key.to_s.downcase
      return true if PATTERNS.any? { |pattern| key_lower.include?(pattern) }

      # Direct configuration access — any raise here propagates to the
      # rescue below and we fail-closed. Wrapping the access in its own
      # rescue would silently fall back to "no extra patterns" on a
      # config bug and the outer rescue would never fire, which means
      # the broken-config path becomes "leak", not "mask".
      user_patterns = EzLogsAgent.configuration.excluded_graphql_variable_keys || []
      user_patterns.any? { |pattern| key_lower.include?(pattern.to_s.downcase) }
    rescue StandardError
      # Defensive: if configuration access raises, treat as sensitive.
      # Better to over-mask than to leak.
      true
    end
  end
end
