# frozen_string_literal: true

require "timeout"

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
    # Exit budget: wait this long for the loop thread, then cap the final send
    STOP_JOIN_SECONDS = 2
    FINAL_FLUSH_SECONDS = 3

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

      # Stop the background flush thread, then send what is still buffered
      # Blocks until thread exits
      # Idempotent: safe to call multiple times
      def stop
        return unless @thread

        @stop_requested = true
        begin
          @thread.wakeup # cut the interval sleep short so exit isn't delayed
        rescue ThreadError
          nil # thread already dead (e.g. the loop crashed): still drain below
        end
        @thread.join(STOP_JOIN_SECONDS)
        @thread = nil

        # Events buffered since the last tick would otherwise be lost at
        # exit (rails runner, rake, deploy restarts). One attempt, short
        # HTTP timeouts, and a hard cap (DNS isn't covered by
        # open_timeout), so a down server can't stall shutdown.
        Timeout.timeout(FINAL_FLUSH_SECONDS) { Transport.batches(Buffer.flush).each { |batch| Transport.send(batch, timeout: 1) } }

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

        Transport.batches(events).each { |batch| RetrySender.send(batch) }
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
