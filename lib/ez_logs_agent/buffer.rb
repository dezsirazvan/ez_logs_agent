# frozen_string_literal: true

require 'monitor'

module EzLogsAgent
  # Thread-safe in-memory event buffer.
  # Stores events until flushed. Drops oldest when full.
  # Never raises exceptions to host application.
  class Buffer
    @queue = []
    @monitor = Monitor.new

    class << self
      # Add event to buffer. Drops oldest if full.
      # @param event [Hash] Event hash from EventBuilder
      # @return [void]
      def push(event)
        @monitor.synchronize do
          if @queue.size >= max_size
            @queue.shift
            log_warn("[Buffer] Buffer full (#{max_size}), dropped oldest event")
          end

          @queue.push(event)
        end
      rescue => error
        log_error("[Buffer] push failed: #{error.message}")
        # Fail open: discard event, never crash host
      end

      # Flush all buffered events and clear buffer atomically.
      # @return [Array<Hash>] Array of events (empty if buffer was empty)
      def flush
        @monitor.synchronize do
          events = @queue.dup
          @queue.clear
          events
        end
      rescue => error
        log_error("[Buffer] flush failed: #{error.message}")
        []
      end

      # Current number of buffered events.
      # @return [Integer]
      def size
        @monitor.synchronize { @queue.size }
      rescue => error
        log_error("[Buffer] size failed: #{error.message}")
        0
      end

      # Clear all buffered events.
      # @return [void]
      def clear
        @monitor.synchronize { @queue.clear }
      rescue => error
        log_error("[Buffer] clear failed: #{error.message}")
        # Best effort, ignore failures
      end

      private

      def max_size
        EzLogsAgent.configuration.buffer_size
      rescue
        100 # Defensive fallback if configuration unavailable
      end

      def log_warn(message)
        EzLogsAgent::Logger.warn(message) if defined?(EzLogsAgent::Logger)
      rescue
        # Logging must never crash the buffer
      end

      def log_error(message)
        EzLogsAgent::Logger.error(message) if defined?(EzLogsAgent::Logger)
      rescue
        # Logging must never crash the buffer
      end
    end
  end
end
