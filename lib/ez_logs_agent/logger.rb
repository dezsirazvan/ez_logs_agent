# frozen_string_literal: true

module EzLogsAgent
  # Minimal, defensive logging utility for the gem.
  # Delegates to Rails.logger when available, falls back to STDERR.
  # Never raises exceptions, never crashes the host application.
  module Logger
    LOG_LEVELS = {
      debug: 0,
      info: 1,
      warn: 2,
      error: 3
    }.freeze

    class << self
      def debug(message)
        log(:debug, message)
      end

      def info(message)
        log(:info, message)
      end

      def warn(message)
        log(:warn, message)
      end

      def error(message)
        log(:error, message)
      end

      private

      def log(level, message)
        # Early return if this log level should not be logged
        return unless should_log?(level)

        prefixed_message = "[EzLogsAgent] #{message}"

        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.public_send(level, prefixed_message)
        else
          # Fallback to stderr when Rails.logger is not available
          # Note: should_log? already checked above, so this respects log_level
          $stderr.puts("[#{level.upcase}] #{prefixed_message}")
        end
      rescue => e
        # Defensive: logging must never crash the host application.
        # Silently swallow any logging errors.
        nil
      end

      def should_log?(level)
        configured_level = EzLogsAgent.configuration.log_level
        LOG_LEVELS[level] >= LOG_LEVELS[configured_level]
      rescue => e
        # If we can't determine log level, allow logging (fail open).
        true
      end
    end
  end
end
