# frozen_string_literal: true

module EzLogsAgent
  # Retry logic with exponential backoff
  #
  # Wraps Transport.send(events) with automatic retry logic.
  # Implements exponential backoff with a maximum delay cap.
  #
  # Responsibilities:
  # - Decides IF and WHEN to retry
  # - Sleeps between retries using exponential backoff
  # - Stops after max attempts
  # - Never crashes the host application
  #
  # Does NOT:
  # - Modify events
  # - Inspect HTTP status codes
  # - Interpret errors
  # - Spawn threads
  # - Read from or flush Buffer
  class RetrySender
    # Maximum sleep duration between retries (hard cap)
    MAX_SLEEP_SECONDS = 5

    # Base delay for exponential backoff calculation
    BASE_DELAY_SECONDS = 0.5

    class << self
      # Send events with retry logic
      #
      # @param events [Array<Hash>] Array of event hashes
      # @return [Symbol] :success if sent successfully, :failure otherwise
      def send(events)
        # Empty events is a success (no work to do)
        return :success if events.nil? || events.empty?

        max_attempts = retry_attempts + 1 # Initial attempt + retries
        attempt = 1

        while attempt <= max_attempts
          result = attempt_send(events, attempt, max_attempts)
          return :success if result == :success

          # If this was the last attempt, return failure
          break if attempt >= max_attempts

          # Sleep before next retry
          sleep_before_retry(attempt)
          attempt += 1
        end

        # All attempts exhausted
        log_final_failure(events.size)
        :failure
      rescue => error
        # Defensive: if anything unexpected happens, log and return failure
        log_error("[RetrySender] send failed with exception: #{error.class} - #{error.message}")
        :failure
      end

      private

      # Attempt to send events once
      def attempt_send(events, attempt, max_attempts)
        Transport.send(events)
      rescue => error
        # Transport shouldn't raise, but be defensive
        log_error("[RetrySender] Transport raised exception (attempt #{attempt}/#{max_attempts}): #{error.message}")
        :failure
      end

      # Sleep with exponential backoff before next retry
      def sleep_before_retry(attempt)
        # Formula: base_delay * (2 ** (attempt - 1))
        # attempt=1: 0.5s, attempt=2: 1.0s, attempt=3: 2.0s, attempt=4: 4.0s, attempt=5: 8.0s
        delay = BASE_DELAY_SECONDS * (2**(attempt - 1))

        # Cap at MAX_SLEEP_SECONDS
        delay = [delay, MAX_SLEEP_SECONDS].min

        sleep(delay)
      rescue => error
        # Defensive: if sleep fails somehow, continue anyway
        log_error("[RetrySender] sleep failed: #{error.message}")
      end

      # Get configured retry attempts, with fallback
      def retry_attempts
        attempts = EzLogsAgent.configuration.retry_attempts

        # Validate and fallback to 3 if invalid
        return 3 if attempts.nil?
        return 3 if !attempts.is_a?(Integer)
        return 3 if attempts < 0

        attempts
      rescue => error
        # Defensive: if configuration fails, use default
        log_error("[RetrySender] Failed to read retry_attempts configuration: #{error.message}")
        3
      end

      # Log final failure after all retries exhausted
      def log_final_failure(event_count)
        Logger.error("[RetrySender] Failed after #{retry_attempts + 1} attempts, dropping #{event_count} events")
      rescue => error
        # Defensive: logging must never crash
        nil
      end

      # Log error message
      def log_error(message)
        Logger.error(message)
      rescue => error
        # Defensive: logging must never crash
        nil
      end
    end
  end
end
