# frozen_string_literal: true

module EzLogsAgent
  # Validates EzLogsAgent configuration and provides actionable error messages.
  #
  # Used at boot-time by Railtie and by the test_connection rake task
  # to ensure configuration is valid before attempting to capture or send events.
  #
  # Validation philosophy:
  # - Only validate what will cause hard failures
  # - Provide clear, actionable error messages
  # - Warnings for optional but recommended config
  # - Never crash the host application
  #
  class ConfigurationValidator
    # Result of configuration validation
    #
    # @attr_reader [Array<String>] errors Critical configuration errors
    # @attr_reader [Array<String>] warnings Non-critical configuration warnings
    ValidationResult = Struct.new(:errors, :warnings) do
      def valid?
        errors.empty?
      end

      def has_warnings?
        warnings.any?
      end
    end

    # Validates the given configuration
    #
    # @param config [EzLogsAgent::Configuration] Configuration to validate
    # @return [ValidationResult] Validation result with errors and warnings
    def self.validate(config)
      errors = []
      warnings = []

      # Required: server_url must be set
      if config.server_url.nil? || config.server_url.to_s.strip.empty?
        errors << "server_url is required. Set it in config/initializers/ez_logs_agent.rb"
      elsif !valid_url?(config.server_url)
        errors << "server_url must be a valid URL (got: #{config.server_url})"
      end

      # Optional but recommended: project_token
      if config.project_token.nil? || config.project_token.to_s.strip.empty?
        warnings << "project_token is not set. Authentication may fail if the server requires it."
      end

      # Validate numeric fields
      if config.buffer_size && (!config.buffer_size.is_a?(Integer) || config.buffer_size <= 0)
        errors << "buffer_size must be a positive integer (got: #{config.buffer_size})"
      end

      if config.retry_attempts && (!config.retry_attempts.is_a?(Integer) || config.retry_attempts < 0)
        errors << "retry_attempts must be a non-negative integer (got: #{config.retry_attempts})"
      end

      if config.send_interval && (!config.send_interval.is_a?(Numeric) || config.send_interval <= 0)
        errors << "send_interval must be a positive number (got: #{config.send_interval})"
      end

      # Validate log_level
      if config.log_level && !valid_log_level?(config.log_level)
        errors << "log_level must be one of: :debug, :info, :warn, :error (got: #{config.log_level})"
      end

      # Validate boolean fields
      unless [true, false].include?(config.capture_http)
        errors << "capture_http must be true or false (got: #{config.capture_http})"
      end

      unless [true, false].include?(config.capture_jobs)
        errors << "capture_jobs must be true or false (got: #{config.capture_jobs})"
      end

      unless [true, false].include?(config.capture_database)
        errors << "capture_database must be true or false (got: #{config.capture_database})"
      end

      # Validate array fields
      if config.excluded_paths && !config.excluded_paths.is_a?(Array)
        errors << "excluded_paths must be an array (got: #{config.excluded_paths.class})"
      end

      if config.excluded_tables && !config.excluded_tables.is_a?(Array)
        errors << "excluded_tables must be an array (got: #{config.excluded_tables.class})"
      end

      if config.excluded_job_classes && !config.excluded_job_classes.is_a?(Array)
        errors << "excluded_job_classes must be an array (got: #{config.excluded_job_classes.class})"
      end

      if config.excluded_graphql_operations && !config.excluded_graphql_operations.is_a?(Array)
        errors << "excluded_graphql_operations must be an array (got: #{config.excluded_graphql_operations.class})"
      end

      # Validate actor_from_request is callable if present
      if config.actor_from_request && !config.actor_from_request.respond_to?(:call)
        errors << "actor_from_request must be a callable (lambda/proc) or nil"
      end

      # Validate display_name_for is a hash if present
      if config.display_name_for && !config.display_name_for.is_a?(Hash)
        errors << "display_name_for must be a hash (got: #{config.display_name_for.class})"
      end

      # Warning if all capture flags are disabled
      if !config.capture_http && !config.capture_jobs && !config.capture_database
        warnings << "All capture flags are disabled. No events will be captured."
      end

      ValidationResult.new(errors, warnings)
    end

    # Checks if the given string is a valid URL
    #
    # @param url [String] URL to validate
    # @return [Boolean] true if valid URL
    def self.valid_url?(url)
      return false unless url.is_a?(String)

      uri = URI.parse(url)
      uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    rescue URI::InvalidURIError
      false
    end

    # Checks if the given log level is valid
    #
    # @param level [Symbol] Log level to validate
    # @return [Boolean] true if valid log level
    def self.valid_log_level?(level)
      %i[debug info warn error].include?(level)
    end

    private_class_method :valid_url?, :valid_log_level?
  end
end
