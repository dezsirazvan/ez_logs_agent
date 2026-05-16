# frozen_string_literal: true

require_relative "ez_logs_agent/version"
require_relative "ez_logs_agent/configuration"
require_relative "ez_logs_agent/configuration_validator"
require_relative "ez_logs_agent/logger"
require_relative "ez_logs_agent/correlation"
require_relative "ez_logs_agent/actor_validator"
require_relative "ez_logs_agent/actor"
require_relative "ez_logs_agent/user_agent_detector"
require_relative "ez_logs_agent/sanitizer"
require_relative "ez_logs_agent/event_builder"
require_relative "ez_logs_agent/resource_extractor"
require_relative "ez_logs_agent/buffer"
require_relative "ez_logs_agent/transport"
require_relative "ez_logs_agent/retry_sender"
require_relative "ez_logs_agent/flush_scheduler"
require_relative "ez_logs_agent/middleware/http_request"
require_relative "ez_logs_agent/capturers/job_capturer"
require_relative "ez_logs_agent/capturers/active_job_capturer"
require_relative "ez_logs_agent/capturers/database_capturer"

# Load Railtie only when Rails is present
require_relative "ez_logs_agent/railtie" if defined?(Rails::Railtie)

module EzLogsAgent
  class Error < StandardError; end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
