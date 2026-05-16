# frozen_string_literal: true

module EzLogsAgent
  # Validates and sanitizes actor data structures.
  #
  # Actor schema:
  # {
  #   id: String,               # REQUIRED, stable identifier
  #   label: String | nil,      # optional, human-readable display
  #   kind: String | nil        # optional, one of human|agent|system|hybrid
  # }
  #
  # This module ensures actors conform to the expected structure
  # before being stored in event context.
  module ActorValidator
    # Valid actor_kind values — keep in sync with the server's Event enum
    # and with `EzLogsAgent::UserAgentDetector` output. Anything outside
    # this set is dropped on sanitize.
    VALID_KINDS = %w[human agent system hybrid].freeze
    class << self
      # Check if an actor structure is valid
      # @param actor [Hash, nil] Actor hash to validate
      # @return [Boolean] true if valid (including nil), false otherwise
      def valid?(actor)
        # nil actor is valid (means "unknown provenance")
        return true if actor.nil?

        # Must be a Hash
        return false unless actor.is_a?(Hash)

        # id is required
        id = actor[:id] || actor["id"]
        return false if id.nil? || id.to_s.empty?

        true
      end

      # Sanitize actor structure to ensure consistent format
      # Returns nil for invalid actors
      # @param actor [Hash, nil] Actor hash to sanitize
      # @return [Hash, nil] Sanitized actor or nil
      def sanitize(actor)
        return nil unless valid?(actor)
        return nil if actor.nil?

        id = actor[:id] || actor["id"]
        label = actor[:label] || actor["label"]
        kind = actor[:kind] || actor["kind"]

        result = { id: id.to_s }
        result[:label] = label.to_s if label
        result[:kind] = kind.to_s if kind && VALID_KINDS.include?(kind.to_s)

        result
      end
    end
  end
end
