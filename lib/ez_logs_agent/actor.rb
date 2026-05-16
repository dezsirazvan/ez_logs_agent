# frozen_string_literal: true

require "request_store"

module EzLogsAgent
  # Manages actor context for the current request.
  #
  # Actor represents "who triggered this action" - the logged-in user.
  #
  # Actor schema:
  # {
  #   id: String,         # REQUIRED - stable identifier (e.g., user.id)
  #   label: String       # optional - human-readable display (e.g., user.email)
  # }
  #
  # Usage:
  #   # Configured via actor_from_request hook in EzLogsAgent.configure
  module Actor
    class << self
      # Get the current actor for this request
      # @return [Hash, nil] Current actor or nil if not set
      def current
        RequestStore.store[:ez_logs_actor]
      rescue => e
        EzLogsAgent::Logger.debug("[Actor] current failed: #{e.message}")
        nil
      end

      # Set the current actor for this request
      # Validates and sanitizes the actor before storing
      # @param actor [Hash, nil] Actor to set
      # @return [Hash, nil] The sanitized actor that was stored
      def current=(actor)
        validated = ActorValidator.sanitize(actor)

        # Log debug message if actor was invalid (user hook misconfiguration)
        if actor && validated.nil?
          EzLogsAgent::Logger.debug("[Actor] Invalid actor structure ignored: #{actor.inspect}")
        end

        RequestStore.store[:ez_logs_actor] = validated
        validated
      rescue => e
        EzLogsAgent::Logger.debug("[Actor] current= failed: #{e.message}")
        nil
      end

      # Clear the current actor
      # @return [void]
      def clear
        RequestStore.store[:ez_logs_actor] = nil
      rescue => e
        EzLogsAgent::Logger.debug("[Actor] clear failed: #{e.message}")
      end
    end
  end
end
