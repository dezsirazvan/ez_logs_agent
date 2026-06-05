# frozen_string_literal: true

require "rails/railtie"

module EzLogsAgent
  # Rails Railtie for automatic zero-config runtime integration.
  #
  # This Railtie is the ONLY orchestrator in EzLogs Agent. It handles:
  # - Starting/stopping the FlushScheduler
  # - Auto-registering HTTP middleware
  # - Auto-registering Sidekiq middleware (client + server)
  # - Auto-installing ActiveJob capturer
  # - Auto-installing Database capturer
  #
  # All integrations are:
  # - Defensive (wrapped in begin/rescue, never crash host app)
  # - Configuration-gated (respect capture_http, capture_jobs, capture_database)
  # - Framework-aware (check defined?(Sidekiq), defined?(ActiveRecord), etc.)
  # - Idempotent (safe to boot multiple times)
  # - Explicitly logged (log what's enabled/skipped and why)
  #
  class Railtie < Rails::Railtie
    # Track registration state for idempotency
    @sidekiq_client_registered = false
    @sidekiq_server_registered = false
    @activejob_installed = false
    @database_capturer_installed = false

    class << self
      attr_accessor :sidekiq_client_registered, :sidekiq_server_registered,
                    :activejob_installed, :database_capturer_installed

      # Reset registration state (for testing)
      def reset_registration_state!
        @sidekiq_client_registered = false
        @sidekiq_server_registered = false
        @activejob_installed = false
        @database_capturer_installed = false
      end
    end

    # =========================================================================
    # HTTP Middleware Registration
    # =========================================================================
    #
    # Registers HTTP request capture middleware into the Rails middleware stack.
    # Runs during Rails initialization (before after_initialize).
    #
    initializer "ez_logs_agent.http_middleware" do |app|
      begin
        if EzLogsAgent.configuration.capture_http
          app.middleware.use EzLogsAgent::Middleware::HttpRequest
          EzLogsAgent::Logger.debug("[Railtie] HTTP capture enabled")
        else
          EzLogsAgent::Logger.debug("[Railtie] HTTP capture disabled (capture_http = false)")
        end
      rescue StandardError => e
        EzLogsAgent::Logger.error("[Railtie] Failed to register HTTP middleware: #{e.class} - #{e.message}")
      end
    end

    # =========================================================================
    # After Initialize: Register Capturers + Setup FlushScheduler
    # =========================================================================
    #
    # This hook runs after Rails has fully initialized. We:
    # 1. Register Sidekiq middleware (if Sidekiq present + capture_jobs enabled)
    # 2. Install ActiveJob capturer (if ActiveJob present + capture_jobs enabled)
    # 3. Install Database capturer (if ActiveRecord present + capture_database enabled)
    # 4. Start FlushScheduler (with special handling for forking servers like Puma)
    #
    # IMPORTANT: FlushScheduler uses a background thread. In forking servers
    # (Puma cluster mode, Unicorn), threads don't survive fork(). We must:
    # - Start FlushScheduler AFTER fork in each worker process
    # - Use server-specific hooks (Puma on_worker_boot, etc.)
    # - Fall back to starting here for non-forking servers (Puma single mode, WEBrick)
    #
    config.after_initialize do
      # Validate configuration before doing anything
      validation_result = validate_configuration
      next unless validation_result

      # Register Sidekiq middleware
      register_sidekiq_middleware

      # Install ActiveJob capturer
      install_activejob_capturer

      # Install Database capturer
      install_database_capturer

      # Setup FlushScheduler with fork-aware initialization
      setup_flush_scheduler

      log_configuration_summary
      EzLogsAgent::Logger.debug("[Railtie] Agent initialized successfully")
    end

    # =========================================================================
    # Shutdown Hook: Stop FlushScheduler
    # =========================================================================
    at_exit do
      begin
        EzLogsAgent::FlushScheduler.stop
        EzLogsAgent::Logger.debug("[Railtie] Agent stopped")
      rescue StandardError => e
        EzLogsAgent::Logger.error("[Railtie] Failed to stop: #{e.class} - #{e.message}")
      end
    end

    # =========================================================================
    # Private Registration Methods
    # =========================================================================

    private

    # Register Sidekiq client and server middleware
    #
    # @return [void]
    def self.register_sidekiq_middleware
      # Check if Sidekiq is present
      unless defined?(Sidekiq)
        EzLogsAgent::Logger.debug("[Railtie] Sidekiq not detected, skipping job capture middleware")
        return
      end

      # Check if job capture is enabled
      unless EzLogsAgent.configuration.capture_jobs
        EzLogsAgent::Logger.debug("[Railtie] Job capture disabled (capture_jobs = false)")
        return
      end

      # Register client middleware (correlation propagation)
      register_sidekiq_client_middleware

      # Register server middleware (job execution capture)
      register_sidekiq_server_middleware
    rescue StandardError => e
      EzLogsAgent::Logger.error("[Railtie] Failed to register Sidekiq middleware: #{e.class} - #{e.message}")
    end

    # Register Sidekiq client middleware
    #
    # Client middleware runs in ALL processes (web, worker, console) and
    # injects correlation_id into job payloads at enqueue-time.
    #
    # @return [void]
    def self.register_sidekiq_client_middleware
      return if @sidekiq_client_registered

      Sidekiq.configure_client do |config|
        config.client_middleware do |chain|
          chain.add EzLogsAgent::Capturers::JobCapturer::ClientMiddleware
        end
      end

      @sidekiq_client_registered = true
      EzLogsAgent::Logger.debug("[Railtie] Sidekiq client middleware registered")
    rescue StandardError => e
      EzLogsAgent::Logger.error("[Railtie] Failed to register Sidekiq client middleware: #{e.class} - #{e.message}")
    end

    # Register Sidekiq server middleware
    #
    # Server middleware runs ONLY in Sidekiq worker processes and
    # captures job execution as background_job events.
    #
    # @return [void]
    def self.register_sidekiq_server_middleware
      return if @sidekiq_server_registered

      Sidekiq.configure_server do |config|
        # Also register client middleware in server process (for job-enqueues-job scenarios)
        config.client_middleware do |chain|
          chain.add EzLogsAgent::Capturers::JobCapturer::ClientMiddleware
        end

        config.server_middleware do |chain|
          chain.add EzLogsAgent::Capturers::JobCapturer::ServerMiddleware
        end
      end

      @sidekiq_server_registered = true
      EzLogsAgent::Logger.debug("[Railtie] Sidekiq server middleware registered")
    rescue StandardError => e
      EzLogsAgent::Logger.error("[Railtie] Failed to register Sidekiq server middleware: #{e.class} - #{e.message}")
    end

    # Install ActiveJob capturer
    #
    # ActiveJob capturer handles correlation propagation and job capture
    # for non-Sidekiq adapters (async, inline, etc.).
    #
    # @return [void]
    def self.install_activejob_capturer
      # Check if ActiveJob is present
      unless defined?(ActiveJob)
        EzLogsAgent::Logger.debug("[Railtie] ActiveJob not detected, skipping ActiveJob capturer")
        return
      end

      # Check if job capture is enabled
      unless EzLogsAgent.configuration.capture_jobs
        # Already logged in register_sidekiq_middleware if Sidekiq present
        # Only log here if Sidekiq is NOT present
        unless defined?(Sidekiq)
          EzLogsAgent::Logger.debug("[Railtie] Job capture disabled (capture_jobs = false)")
        end
        return
      end

      return if @activejob_installed

      EzLogsAgent::Capturers::ActiveJobCapturer.install
      @activejob_installed = true
      EzLogsAgent::Logger.debug("[Railtie] ActiveJob capturer installed")
    rescue StandardError => e
      EzLogsAgent::Logger.error("[Railtie] Failed to install ActiveJob capturer: #{e.class} - #{e.message}")
    end

    # Install Database capturers (per-row + bulk).
    #
    # Two capturers, one switch (`capture_database`):
    # - DatabaseCapturer: per-row CRUD via after_create / _update / _destroy.
    # - BulkDatabaseCapturer: bulk SQL via ActiveSupport::Notifications
    #   ("sql.active_record"), narrowly filtered to delete_all / update_all /
    #   insert_all / upsert_all. Catches what callbacks can't see.
    #
    # @return [void]
    def self.install_database_capturer
      # Check if ActiveRecord is present
      unless defined?(ActiveRecord)
        EzLogsAgent::Logger.debug("[Railtie] ActiveRecord not detected, skipping database capture")
        return
      end

      # Check if database capture is enabled
      unless EzLogsAgent.configuration.capture_database
        EzLogsAgent::Logger.debug("[Railtie] Database capture disabled (capture_database = false)")
        return
      end

      return if @database_capturer_installed

      EzLogsAgent::Capturers::DatabaseCapturer.install
      EzLogsAgent::Capturers::BulkDatabaseCapturer.install
      @database_capturer_installed = true
      EzLogsAgent::Logger.debug("[Railtie] Database capture installed (per-row + bulk)")
    rescue StandardError => e
      EzLogsAgent::Logger.error("[Railtie] Failed to install database capturer: #{e.class} - #{e.message}")
    end

    # Setup FlushScheduler with fork-aware initialization
    #
    # Background threads don't survive fork(). In forking servers like Puma
    # cluster mode or Unicorn, we must start FlushScheduler AFTER the fork
    # in each worker process.
    #
    # Strategy:
    # 1. Always register ActiveSupport::ForkTracker hook (handles all forking cases)
    # 2. Also start immediately (for non-forking servers or single-process mode)
    # 3. FlushScheduler.start is idempotent, so calling it multiple times is safe
    #
    # @return [void]
    def self.setup_flush_scheduler
      # Register fork hook for Puma cluster mode, Unicorn, etc.
      # ActiveSupport::ForkTracker (Rails 6.1+) is the most reliable way
      if defined?(ActiveSupport::ForkTracker)
        ActiveSupport::ForkTracker.after_fork do
          start_flush_scheduler
        end
        EzLogsAgent::Logger.debug("[Railtie] Registered ActiveSupport::ForkTracker hook for FlushScheduler")
      end

      # Always start FlushScheduler now (for non-forking servers or master process)
      # In forking servers, this runs in master (will be killed on fork)
      # then ForkTracker restarts it in each worker
      start_flush_scheduler
    rescue StandardError => e
      EzLogsAgent::Logger.error("[Railtie] Failed to setup FlushScheduler: #{e.class} - #{e.message}")
    end

    # Start the FlushScheduler
    #
    # @return [void]
    def self.start_flush_scheduler
      EzLogsAgent::FlushScheduler.start
      EzLogsAgent::Logger.debug("[Railtie] FlushScheduler started (PID: #{Process.pid})")
    rescue StandardError => e
      EzLogsAgent::Logger.error("[Railtie] Failed to start FlushScheduler: #{e.class} - #{e.message}")
    end

    # Validate configuration at boot time
    #
    # Logs errors and warnings from configuration validation.
    # If configuration is invalid, logs errors and returns false to skip initialization.
    # If configuration has warnings, logs them but continues.
    #
    # @return [Boolean] true if valid or has only warnings, false if invalid
    def self.validate_configuration
      result = EzLogsAgent::ConfigurationValidator.validate(EzLogsAgent.configuration)

      # Log errors
      if result.errors.any?
        EzLogsAgent::Logger.error("[Railtie] Configuration validation failed:")
        result.errors.each do |error|
          EzLogsAgent::Logger.error("[Railtie]   - #{error}")
        end
        EzLogsAgent::Logger.error("[Railtie] Agent initialization skipped. Please fix configuration errors.")
        return false
      end

      # Log warnings
      if result.warnings.any?
        result.warnings.each do |warning|
          EzLogsAgent::Logger.warn("[Railtie]   ⚠ #{warning}")
        end
      end

      true
    rescue StandardError => e
      EzLogsAgent::Logger.error("[Railtie] Failed to validate configuration: #{e.class} - #{e.message}")
      false
    end

    # Log configuration summary at boot time
    #
    # Shows what's enabled/disabled to help with debugging and visibility.
    #
    # @return [void]
    def self.log_configuration_summary
      config = EzLogsAgent.configuration

      EzLogsAgent::Logger.info("[Railtie] Configuration:")
      EzLogsAgent::Logger.info("[Railtie]   Server: #{config.server_url}")
      EzLogsAgent::Logger.info("[Railtie]   Capture HTTP: #{config.capture_http}")
      EzLogsAgent::Logger.info("[Railtie]   Capture Jobs: #{config.capture_jobs}")
      EzLogsAgent::Logger.info("[Railtie]   Capture Database: #{config.capture_database}")

      # Show optional configuration if present
      if config.actor_from_request
        EzLogsAgent::Logger.info("[Railtie]   Actor Extraction: enabled")
      end

      if config.display_name_for && config.display_name_for.any?
        EzLogsAgent::Logger.info("[Railtie]   Display Names: configured for #{config.display_name_for.keys.join(', ')}")
      end
    rescue StandardError => e
      EzLogsAgent::Logger.error("[Railtie] Failed to log configuration summary: #{e.class} - #{e.message}")
    end

    # Load rake tasks
    rake_tasks do
      load "tasks/ez_logs_agent.rake"
    end
  end
end
