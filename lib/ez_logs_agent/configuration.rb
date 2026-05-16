# frozen_string_literal: true

module EzLogsAgent
  # Configuration for the EzLogsAgent.
  #
  # == Noise Filtering Overview
  #
  # EzLogsAgent captures events but filters out noise at the agent level.
  # Each capturer has its own exclusion mechanism:
  #
  # === HTTP Requests (middleware/http_request.rb)
  # - excluded_paths: URL paths to ignore (supports * wildcard for prefix match)
  # - DEFAULT_EXCLUDED_EXTENSIONS: Static file extensions (.js, .css, .png, etc.)
  # - excluded_graphql_operations: GraphQL operations to skip (introspection, etc.)
  #
  # === Database Callbacks (capturers/database_capturer.rb)
  # - excluded_tables: Table names to ignore (Rails internals, job queues, etc.)
  # - IGNORED_ATTRIBUTES: Technical fields (created_at, lock_version, etc.)
  # - SENSITIVE_PATTERNS: Attributes containing passwords, tokens, secrets
  #
  # === Background Jobs (capturers/job_capturer.rb)
  # - excluded_job_classes: Job class names to ignore (health checks, etc.)
  #
  # == Server-Side vs Agent-Side Filtering
  #
  # The filtering philosophy:
  # - Agent filters NOISE (introspection, assets, health checks, Rails internals)
  # - Server classifies SIGNIFICANCE (reads vs writes) for UI filtering
  #
  # This means GraphQL queries and GET requests ARE captured by the agent,
  # but the server classifies them as "background" so users can toggle visibility.
  #
  class Configuration
    attr_accessor :server_url
    attr_accessor :project_token
    attr_accessor :capture_http
    attr_accessor :capture_jobs
    attr_accessor :capture_database
    attr_accessor :excluded_paths
    attr_accessor :excluded_tables
    attr_accessor :excluded_job_classes
    attr_accessor :excluded_graphql_operations
    attr_accessor :excluded_graphql_variable_keys
    attr_accessor :buffer_size
    attr_accessor :retry_attempts
    attr_accessor :send_interval
    attr_accessor :log_level

    # Actor extraction hook for HTTP requests (optional)
    # Must be a callable (lambda/proc) that accepts (request, controller)
    # and returns { kind:, id:, label:, metadata: } or nil
    attr_accessor :actor_from_request

    # Display name field mapping for database records (optional)
    # Maps model class names to attribute names used for human-readable display
    #
    # Example:
    #   config.display_name_for = {
    #     "User" => :email,
    #     "Product" => :name,
    #     "Order" => :number
    #   }
    #
    # IMPORTANT: Only use direct attributes, not associations.
    # Associations will trigger database queries and should be avoided.
    #
    # If not configured for a model, falls back to: name → title → number → "##{id}"
    attr_accessor :display_name_for

    # Default paths excluded from HTTP capture - common Rails noise
    DEFAULT_EXCLUDED_PATHS = [
      "/rails/active_storage*",  # File uploads/downloads
      "/assets*",                # Asset pipeline
      "/packs*",                 # Webpacker assets
      "/vite*",                  # Vite assets
      "/health*",                # Health checks
      "/up",                     # Rails 7.1+ health check
      "/alive",                  # Kubernetes liveness probe
      "/ready",                  # Kubernetes readiness probe
      "/metrics",                # Prometheus metrics endpoint
      "/favicon.ico",            # Browser favicon
      "/*.hot-update.*",         # Hot module replacement
      "/.well-known*",           # Well-known URIs (security.txt, etc.)
      "/robots.txt",             # Search engine crawler config
      "/sitemap.xml",            # Sitemap for crawlers
      "/cable*",                 # ActionCable WebSocket connections
      "/sidekiq",                # Sidekiq Web UI dashboard root (the conventional mount)
      "/sidekiq/*",              # Sidekiq Web UI sub-paths (auto-poll noise)
      # Authentication pages - not meaningful business actions
      # Use */path* patterns to match auth routes anywhere (e.g., /admin/logout)
      "*/sign_in*",              # Devise and common sign in (matches /users/sign_in, /admin/sign_in)
      "*/sign_out*",             # Devise and common sign out
      "*/login*",                # Common auth pattern (matches /login, /admin/login)
      "*/logout*",               # Common auth pattern (matches /logout, /admin/logout)
      "/users/password*",        # Devise password reset/edit
      "/session*"                # Common auth pattern
    ].freeze

    # Default file extensions excluded from HTTP capture - static assets
    # These are matched against the path suffix regardless of directory
    DEFAULT_EXCLUDED_EXTENSIONS = %w[
      .js .css .map
      .png .jpg .jpeg .gif .svg .ico .webp
      .woff .woff2 .ttf .eot .otf
    ].freeze

    # Default tables excluded from database capture - Rails internal tables
    DEFAULT_EXCLUDED_TABLES = [
      "schema_migrations",
      "ar_internal_metadata",
      "sessions",                         # ActiveRecord session store (plural)
      "session",                          # ActiveRecord session store (singular)
      "active_storage_blobs",             # ActiveStorage internals
      "active_storage_attachments",
      "active_storage_variant_records",
      "solid_queue_jobs",                 # SolidQueue internals
      "solid_queue_scheduled_executions",
      "solid_queue_ready_executions",
      "solid_queue_claimed_executions",
      "solid_queue_blocked_executions",
      "solid_queue_failed_executions",
      "solid_queue_pauses",
      "solid_queue_processes",
      "solid_queue_semaphores",
      "solid_queue_recurring_tasks",
      "solid_queue_recurring_executions",
      "solid_cache_entries",              # SolidCache internals
      "solid_cable_messages"              # SolidCable internals
    ].freeze

    # Default job classes excluded from background job capture - infrastructure/health check jobs
    DEFAULT_EXCLUDED_JOB_CLASSES = [
      "SidekiqAlive::Worker",             # Sidekiq health check
      "SolidQueue::CleanupJob",           # SolidQueue maintenance
      "SolidQueue::RecurringJob"          # SolidQueue scheduler internals
    ].freeze

    # Default GraphQL operations excluded from capture - introspection and IDE queries
    # Supports exact match and prefix match (patterns ending with *)
    DEFAULT_EXCLUDED_GRAPHQL_OPERATIONS = [
      "IntrospectionQuery",               # Standard IDE introspection query
      "__*"                               # All introspection fields (__schema, __type, etc.)
    ].freeze

    def initialize
      @server_url = nil
      @project_token = nil
      @capture_http = true
      @capture_jobs = true
      @capture_database = true
      @excluded_paths = []                 # User-defined; combined with DEFAULT_EXCLUDED_PATHS
      @excluded_tables = []                # User-defined; combined with DEFAULT_EXCLUDED_TABLES
      @excluded_job_classes = []           # User-defined; combined with DEFAULT_EXCLUDED_JOB_CLASSES
      @excluded_graphql_operations = []    # User-defined; combined with DEFAULT_EXCLUDED_GRAPHQL_OPERATIONS
      @excluded_graphql_variable_keys = [] # User-defined; additional sensitive variable key patterns to filter
      @buffer_size = 10_000                # Increased for high-volume workloads (job-heavy apps)
      @retry_attempts = 3
      @send_interval = 3                   # More frequent sends for better throughput
      @log_level = :warn
      @actor_from_request = nil  # Not configured by default
      @display_name_for = {}     # Not configured by default
    end

    # Returns all excluded paths (defaults + user-configured)
    def all_excluded_paths
      DEFAULT_EXCLUDED_PATHS + (@excluded_paths || [])
    end

    # Returns all excluded tables (defaults + user-configured)
    def all_excluded_tables
      DEFAULT_EXCLUDED_TABLES + (@excluded_tables || [])
    end

    # Returns all excluded job classes (defaults + user-configured)
    def all_excluded_job_classes
      DEFAULT_EXCLUDED_JOB_CLASSES + (@excluded_job_classes || [])
    end

    # Returns all excluded GraphQL operations (defaults + user-configured)
    def all_excluded_graphql_operations
      DEFAULT_EXCLUDED_GRAPHQL_OPERATIONS + (@excluded_graphql_operations || [])
    end
  end
end
