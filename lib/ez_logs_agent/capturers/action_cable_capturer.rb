# frozen_string_literal: true

module EzLogsAgent
  module Capturers
    # Action Cable channel actions (a chat message, a live form): their writes run on Action Cable's
    # worker threads, outside any request, so they had no correlation and were stored but never
    # shown. Each channel action is one action, named by the person the connection belongs to
    # (the app's actor_from_request hook, called with the connection's own request env).
    module ActionCableCapturer
      CORRELATION_KEY = EzLogsAgent::Command::CORRELATION_KEY
      STARTED_KEY = EzLogsAgent::Command::STARTED_KEY
      ACTOR_KEY = EzLogsAgent::Command::ACTOR_KEY

      # Prepended to ActionCable::Channel::Base: the action runs exactly as before.
      module ChannelAction
        def perform_action(data)
          started = EzLogsAgent::Capturers::ActionCableCapturer.start(self)
          super
        ensure
          EzLogsAgent::Command.finish if started
        end
      end

      module_function

      def install
        return unless defined?(::ActionCable::Channel::Base)
        return if ::ActionCable::Channel::Base <= ChannelAction

        ::ActionCable::Channel::Base.prepend(ChannelAction)
      rescue StandardError => e
        EzLogsAgent::Logger.error("[ActionCableCapturer] install failed: #{e.class} - #{e.message}")
      end

      # @return [Boolean] whether this call started the action's scope
      def start(channel)
        return false unless EzLogsAgent.configuration.capture_database
        return false if EzLogsAgent::Correlation.current

        id = EzLogsAgent::Correlation.generate
        EzLogsAgent::Correlation.current = id
        store = RequestStore.store
        store[CORRELATION_KEY] = id
        store[STARTED_KEY] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        actor = actor_for(channel)
        store[ACTOR_KEY] = actor if actor
        true
      rescue StandardError => e
        EzLogsAgent::Logger.debug("[ActionCableCapturer] start failed: #{e.message}")
        false
      end

      def actor_for(channel)
        hook = EzLogsAgent.configuration.actor_from_request
        return nil unless hook.respond_to?(:call)

        env = channel.connection.respond_to?(:env) ? channel.connection.env : nil
        actor = env && hook.call(env, nil)
        actor.is_a?(Hash) && EzLogsAgent::ActorValidator.valid?(actor) ? EzLogsAgent::ActorValidator.sanitize(actor) : nil
      rescue StandardError
        nil
      end
    end
  end
end
