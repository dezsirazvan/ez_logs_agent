# frozen_string_literal: true

module EzLogsAgent
  # FlushScheduler orchestrates periodic flushing of buffered events to the server.
  #
  # Responsibilities:
  # - Start a single background thread that wakes up every `send_interval` seconds
  # - Flush Buffer and send events via RetrySender
  # - Shut down cleanly when requested
  #
  # Non-responsibilities:
  # - Does NOT retry (RetrySender handles that)
  # - Does NOT interpret Transport results
  # - Does NOT manage Rails lifecycle (Railtie handles that)
  # - Does NOT mutate or inspect events
  class FlushScheduler
    class << self
      # Start the background flush thread
      # Idempotent: safe to call multiple times
      def start
        return if running?

        @stop_requested = false
        @thread = Thread.new { run_loop }

        Logger.debug("[FlushScheduler] Started")
      rescue => error
        Logger.error("[FlushScheduler] Failed to start: #{error.class} - #{error.message}")
      end

      # Stop the background flush thread
      # Blocks until thread exits
      # Idempotent: safe to call multiple times
      def stop
        return unless running?

        @stop_requested = true
        @thread.join if @thread

        Logger.debug("[FlushScheduler] Stopped")
      rescue => error
        Logger.error("[FlushScheduler] Failed to stop: #{error.class} - #{error.message}")
      end

      # Check if the scheduler is currently running
      def running?
        @thread&.alive? == true
      end

      private

      # Background loop: sleep → flush → send → repeat
      def run_loop
        loop do
          break if @stop_requested

          sleep_interval
          break if @stop_requested

          flush_and_send
        end
      rescue => error
        Logger.error("[FlushScheduler] Loop crashed: #{error.class} - #{error.message}")
      end

      # Sleep for configured interval
      def sleep_interval
        interval = send_interval
        sleep(interval)
      rescue => error
        Logger.error("[FlushScheduler] Sleep failed: #{error.message}")
        sleep(5) # Defensive fallback
      end

      # Flush buffer and send events
      def flush_and_send
        events = Buffer.flush
        return if events.nil? || events.empty?

        RetrySender.send(events)
      rescue => error
        Logger.error("[FlushScheduler] Flush and send failed: #{error.class} - #{error.message}")
      end

      # Get send_interval from configuration with defensive fallback
      def send_interval
        interval = EzLogsAgent.configuration.send_interval
        return 5 if interval.nil?
        return 5 if !interval.is_a?(Numeric)
        return 5 if interval <= 0

        interval
      rescue => error
        Logger.error("[FlushScheduler] Failed to read send_interval: #{error.message}")
        5
      end
    end
  end
end
