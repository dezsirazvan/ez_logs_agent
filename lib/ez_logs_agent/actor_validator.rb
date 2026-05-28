# frozen_string_literal: true

module EzLogsAgent
  # Validates and sanitizes actor data structures.
  #
  # Actor schema:
  # {
  #   id: String,                       # REQUIRED, stable identifier
  #   label: String | nil,              # optional, human-readable display
  #   kind: String | nil,               # optional, one of human|agent|system|hybrid
  #   principal: { id:, label? } | nil  # optional, only meaningful when
  #                                     # kind == "hybrid": the human who
  #                                     # authorized the agent. Drives the
  #                                     # "Claude updated employee, on
  #                                     # behalf of Razvan" framing on the
  #                                     # server's AiExplainer.
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
        principal = actor[:principal] || actor["principal"]

        result = { id: id.to_s }
        result[:label] = label.to_s if label
        result[:kind] = kind.to_s if kind && VALID_KINDS.include?(kind.to_s)
        sanitized_principal = sanitize_principal(principal)
        result[:principal] = sanitized_principal if sanitized_principal

        result
      end

      private

      # Sanitize the optional principal sub-structure. Reuses the same
      # "id required, label optional" shape as the top-level actor — but
      # principals are always human, so no `kind` field. Returns nil if
      # the principal is missing or malformed (we drop silently rather
      # than rejecting the whole actor; principal is purely advisory).
      def sanitize_principal(principal)
        return nil if principal.nil?
        return nil unless principal.is_a?(Hash)

        id = principal[:id] || principal["id"]
        return nil if id.nil? || id.to_s.empty?

        result = { id: id.to_s }
        label = principal[:label] || principal["label"]
        result[:label] = label.to_s if label
        result
      end
    end
  end
end
