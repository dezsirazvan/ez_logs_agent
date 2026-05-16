# frozen_string_literal: true

module EzLogsAgent
  module Middleware
    # Rack middleware for capturing HTTP requests as Events.
    #
    # Responsibilities:
    # - Wrap request lifecycle
    # - Measure duration
    # - Extract HTTP metadata
    # - Build Events via EventBuilder
    # - Push Events into Buffer
    # - Never crash host application
    #
    # This middleware is purely additive and defensive.
    # It NEVER swallows exceptions from downstream.
    class HttpRequest
      def initialize(app)
        @app = app
      end

      # Rack interface: call(env)
      # @param env [Hash] Rack environment
      # @return [Array] Rack response tuple [status, headers, body]
      def call(env)
        # Skip capturing if disabled or path excluded
        return @app.call(env) unless should_capture?(env)

        # Generate correlation_id at request entry
        # This establishes the correlation context for all downstream operations
        # (model callbacks, job enqueues, nested service calls, etc.)
        setup_correlation

        start_time = current_time_ms
        status = nil
        exception = nil
        graphql_response_errors = nil

        begin
          # Call downstream app
          status, headers, body = @app.call(env)

          # SAFETY CRITICAL: We NEVER touch, modify, reassign, or interfere with
          # the response body in any way. The body variable flows through untouched.
          #
          # For GraphQL error detection, we use a READ-ONLY extraction that:
          # - Never reassigns the body variable
          # - Never calls any methods on the body object
          # - Only reads if body is a plain Array of plain Strings (already buffered)
          # - Returns nil on ANY doubt
          #
          # This sacrifices some error detection for absolute safety.
          if graphql_request?(env) && status == 200
            graphql_response_errors = safely_read_graphql_errors(body)
          end

          [status, headers, body]
        rescue => e
          # Capture exception but re-raise after
          exception = e
          raise
        ensure
          # Extract actor after request completes (when controller context is available)
          # This sets Actor.current for inclusion in event context
          extract_and_set_actor(env)

          # Always capture event (success or failure)
          capture_event(env, start_time, status, exception, graphql_response_errors)

          # Clean up correlation and actor context after request completes
          clear_correlation
          clear_actor
        end
      end

      private

      # Determine if request should be captured
      # @param env [Hash] Rack environment
      # @return [Boolean]
      def should_capture?(env)
        return false unless capture_enabled?
        return false if excluded_path?(env)
        true
      rescue => e
        log_error("should_capture? failed: #{e.message}")
        false # Fail closed: don't capture if decision logic crashes
      end

      # Check if HTTP capture is enabled
      # @return [Boolean]
      def capture_enabled?
        EzLogsAgent.configuration.capture_http
      rescue
        false # Defensive: assume disabled if config unavailable
      end

      # Check if request path is excluded
      # Uses all_excluded_paths which combines defaults with user-configured
      # Supports both exact match and prefix match (paths ending with *)
      # Also checks file extensions (e.g., .js, .css, .png)
      # @param env [Hash] Rack environment
      # @return [Boolean]
      def excluded_path?(env)
        path = env["PATH_INFO"] || ""

        # Check path patterns first
        all_excluded = EzLogsAgent.configuration.all_excluded_paths
        return true if all_excluded.any? { |pattern| path_matches?(path, pattern) }

        # Check file extensions
        return true if excluded_extension?(path)

        false
      rescue => e
        log_error("excluded_path? failed: #{e.message}")
        false # Defensive: don't exclude if check fails
      end

      # Check if path matches an exclusion pattern
      # @param path [String] Request path
      # @param pattern [String] Exclusion pattern
      # Supports:
      #   - Exact match: "/favicon.ico"
      #   - Prefix match: "/rails/active_storage*"
      #   - Suffix match: "*/logout" (matches /admin/logout, /logout)
      #   - Contains match: "*/logout*" (matches /admin/logout, /logout/callback)
      # @return [Boolean]
      def path_matches?(path, pattern)
        starts_with_star = pattern.start_with?("*")
        ends_with_star = pattern.end_with?("*")

        if starts_with_star && ends_with_star
          # Contains match: "*/logout*" matches any path containing "/logout"
          middle = pattern[1..-2] # Remove both *s
          path.include?(middle)
        elsif starts_with_star
          # Suffix match: "*/logout" matches paths ending with "/logout"
          suffix = pattern[1..-1] # Remove leading *
          path.end_with?(suffix)
        elsif ends_with_star
          # Prefix match: "/rails/active_storage*" matches "/rails/active_storage/..."
          path.start_with?(pattern.chomp("*"))
        else
          # Exact match
          path == pattern
        end
      end

      # Check if path has an excluded file extension
      # @param path [String] Request path
      # @return [Boolean]
      def excluded_extension?(path)
        return false if path.nil? || path.empty?

        # Get extensions to check
        extensions = EzLogsAgent::Configuration::DEFAULT_EXCLUDED_EXTENSIONS

        # Check if path ends with any excluded extension
        extensions.any? { |ext| path.end_with?(ext) }
      rescue => e
        log_error("excluded_extension? failed: #{e.message}")
        false
      end

      # Capture event and push to buffer
      # @param env [Hash] Rack environment
      # @param start_time [Integer] Request start time (ms)
      # @param status [Integer, nil] HTTP status code
      # @param exception [Exception, nil] Exception if raised
      # @param graphql_response_errors [String, nil] GraphQL errors from response body
      # @return [void]
      def capture_event(env, start_time, status, exception, graphql_response_errors = nil)
        duration_ms = current_time_ms - start_time
        outcome, error_message = determine_outcome(status, exception, graphql_response_errors)

        # Convert start_time (ms) to Time object for EventBuilder
        # This ensures events are timestamped at START, not completion
        start_timestamp = Time.at(start_time / 1000.0).utc

        event = build_event(
          env: env,
          status: status,
          duration_ms: duration_ms,
          outcome: outcome,
          error_message: error_message,
          timestamp: start_timestamp
        )

        EzLogsAgent::Buffer.push(event) if event
      rescue => e
        # NEVER crash host app, even if event capture fails
        log_error("capture_event failed: #{e.message}")
      end

      # Build Event hash via EventBuilder
      # @param env [Hash] Rack environment
      # @param status [Integer, nil] HTTP status code
      # @param duration_ms [Integer] Request duration
      # @param outcome [String] "success" or "failure"
      # @param error_message [String, nil] Error message if failure
      # @param timestamp [Time] Request start time
      # @return [Hash, nil] Event hash or nil if build fails or should be skipped
      def build_event(env:, status:, duration_ms:, outcome:, error_message:, timestamp:)
        source_data = extract_source_data(env, status)

        # Skip if source_data indicates this request should not be captured
        return nil if source_data == :skip

        EzLogsAgent::EventBuilder.build(
          source_type: "http_request",
          source_data: source_data,
          outcome: outcome,
          correlation_id: current_correlation_id,
          resource_ids: [],
          context: extract_context,
          duration_ms: duration_ms,
          error_message: error_message,
          timestamp: timestamp
        )
      rescue => e
        log_error("build_event failed: #{e.message}")
        nil # Return nil if event construction fails
      end

      # Extract source_data hash from Rack env
      # @param env [Hash] Rack environment
      # @param status [Integer, nil] HTTP status code
      # @return [Hash]
      def extract_source_data(env, status)
        base_data = {
          method: env["REQUEST_METHOD"],
          path: env["PATH_INFO"],
          status_code: status,
          controller: extract_controller(env),
          action: extract_action(env),
          format: extract_format(env),
          user_agent: env["HTTP_USER_AGENT"],
          remote_ip: extract_remote_ip(env)
        }

        # Add GraphQL metadata if this is a GraphQL request
        graphql_data = extract_graphql_metadata(env)

        # Skip capturing GraphQL queries
        return :skip if graphql_data == :skip

        if graphql_data
          base_data.merge!(graphql_data)
        else
          # For non-GraphQL requests, capture request params
          # - GET requests: query string params
          # - POST/PATCH/PUT/DELETE: body params
          rest_params = extract_rest_params(env)
          base_data[:request_params] = rest_params if rest_params
        end

        base_data.compact # Remove nil values
      rescue => e
        log_error("extract_source_data failed: #{e.message}")
        {} # Return empty hash if extraction fails
      end

      # Extract Rails controller name (if available)
      # @param env [Hash] Rack environment
      # @return [String, nil]
      def extract_controller(env)
        return nil unless env["action_dispatch.request.path_parameters"]

        env["action_dispatch.request.path_parameters"][:controller]
      end

      # Extract Rails action name (if available)
      # @param env [Hash] Rack environment
      # @return [String, nil]
      def extract_action(env)
        return nil unless env["action_dispatch.request.path_parameters"]

        env["action_dispatch.request.path_parameters"][:action]
      end

      # Extract format (json, html, etc.) if available
      # @param env [Hash] Rack environment
      # @return [String, nil]
      def extract_format(env)
        # Try Rails format first
        if env["action_dispatch.request.path_parameters"]
          format = env["action_dispatch.request.path_parameters"][:format]
          return format if format
        end

        # Fallback to CONTENT_TYPE parsing
        content_type = env["CONTENT_TYPE"]
        return "json" if content_type&.include?("json")
        return "xml" if content_type&.include?("xml")

        nil
      end

      # Extract remote IP address
      # @param env [Hash] Rack environment
      # @return [String, nil]
      def extract_remote_ip(env)
        # Check X-Forwarded-For first (proxy scenarios)
        if env["HTTP_X_FORWARDED_FOR"]
          return env["HTTP_X_FORWARDED_FOR"].split(",").first&.strip
        end

        # Fallback to REMOTE_ADDR
        env["REMOTE_ADDR"]
      end

      # Extract GraphQL metadata from request body (if applicable)
      # @param env [Hash] Rack environment
      # @return [Hash, nil] GraphQL metadata or nil if not a GraphQL request
      # @return [:skip] Special return value indicating request should not be captured
      def extract_graphql_metadata(env)
        # Only process POST requests to /graphql path
        return nil unless env["REQUEST_METHOD"] == "POST"
        return nil unless graphql_path?(env["PATH_INFO"])

        # Read request body
        body = read_request_body(env)
        return nil if body.nil? || body.empty?

        # Parse JSON body
        parsed = JSON.parse(body)
        return nil unless parsed.is_a?(Hash)

        query_string = parsed["query"]
        operation_name = parsed["operationName"]

        # If operationName not provided, try to extract from query string
        # e.g., "query blueprints($ids: [ID!]) { ... }" → "blueprints"
        operation_name ||= extract_operation_name_from_query(query_string)

        # Check if operation is excluded (introspection, etc.)
        return :skip if excluded_graphql_operation?(operation_name)

        # Extract GraphQL operation details from query string
        operation_type = infer_operation_type(query_string)

        # If we couldn't determine type from query, infer from operation name
        operation_type ||= infer_operation_type_from_name(operation_name)

        # Extract and sanitize GraphQL variables
        variables = sanitize_graphql_variables(parsed["variables"])

        # Capture all GraphQL operations (queries, mutations, subscriptions)
        # Server-side significance classification handles filtering in the UI
        {
          graphql_operation: operation_name || "anonymous",
          graphql_type: operation_type,
          graphql_variables: variables
        }.compact
      rescue JSON::ParserError => e
        log_error("extract_graphql_metadata JSON parse failed: #{e.message}")
        nil
      rescue => e
        log_error("extract_graphql_metadata failed: #{e.message}")
        nil
      end

      # Extract params from REST requests
      # - GET requests: query string params
      # - POST/PATCH/PUT/DELETE: body params
      #
      # @param env [Hash] Rack environment
      # @return [Hash, nil] Sanitized request params or nil
      def extract_rest_params(env)
        method = env["REQUEST_METHOD"]

        # Skip GraphQL endpoints (handled separately)
        return nil if graphql_path?(env["PATH_INFO"])

        if method == "GET"
          extract_query_string_params(env)
        elsif %w[POST PATCH PUT DELETE].include?(method)
          extract_body_params(env)
        end
      rescue => e
        log_error("extract_rest_params failed: #{e.message}")
        nil
      end

      # Extract and sanitize query string params for GET requests
      # @param env [Hash] Rack environment
      # @return [Hash, nil] Sanitized query params or nil
      def extract_query_string_params(env)
        query_string = env["QUERY_STRING"]
        return nil if query_string.nil? || query_string.empty?

        # Parse query string using Rack's utility
        params = Rack::Utils.parse_nested_query(query_string)
        return nil if params.empty?

        sanitize_rest_params(params)
      rescue => e
        log_error("extract_query_string_params failed: #{e.message}")
        nil
      end

      # Extract body params from mutation requests (POST, PATCH, PUT, DELETE)
      #
      # Tries multiple sources in order:
      # 1. Rails filtered_parameters (after controller processing)
      # 2. Rack form hash (for form-encoded submissions)
      # 3. JSON body parsing (for API requests)
      #
      # @param env [Hash] Rack environment
      # @return [Hash, nil] Sanitized request params or nil
      def extract_body_params(env)
        # Try Rails filtered_parameters first (best option - already filtered)
        params = extract_rails_params(env)
        return sanitize_rest_params(params) if params && !params.empty?

        # Try Rack's parsed form data (for form submissions)
        params = extract_rack_form_params(env)
        return sanitize_rest_params(params) if params && !params.empty?

        # Fallback: parse JSON body if Content-Type is JSON
        params = extract_json_body_params(env)
        return sanitize_rest_params(params) if params && !params.empty?

        nil
      rescue => e
        log_error("extract_body_params failed: #{e.message}")
        nil
      end

      # Extract params from Rails request if available
      # @param env [Hash] Rack environment
      # @return [Hash, nil]
      def extract_rails_params(env)
        # Rails stores filtered params after controller processing
        request = env["action_dispatch.request"]
        return nil unless request
        return nil unless request.respond_to?(:filtered_parameters)

        # Get filtered params (sensitive values already filtered by Rails)
        params = request.filtered_parameters
        return nil unless params.is_a?(Hash)

        # Remove Rails internal params (controller, action, format)
        params = params.except("controller", "action", "format", "authenticity_token")
        params.empty? ? nil : params
      rescue => e
        log_error("extract_rails_params failed: #{e.message}")
        nil
      end

      # Extract params from Rack's form hash (for form-encoded submissions)
      # @param env [Hash] Rack environment
      # @return [Hash, nil]
      def extract_rack_form_params(env)
        # Rack stores parsed form data in this key
        params = env["rack.request.form_hash"]
        return nil unless params.is_a?(Hash)
        return nil if params.empty?

        # Remove Rails internal params
        params = params.except("controller", "action", "format", "authenticity_token", "_method")
        params.empty? ? nil : params
      rescue => e
        log_error("extract_rack_form_params failed: #{e.message}")
        nil
      end

      # Extract params from JSON body
      # @param env [Hash] Rack environment
      # @return [Hash, nil]
      def extract_json_body_params(env)
        content_type = env["CONTENT_TYPE"].to_s
        return nil unless content_type.include?("json")

        body = read_request_body(env)
        return nil if body.nil? || body.empty?

        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError => e
        log_error("extract_json_body_params JSON parse failed: #{e.message}")
        nil
      rescue => e
        log_error("extract_json_body_params failed: #{e.message}")
        nil
      end

      # Sanitize REST params (reuses GraphQL sanitization logic)
      # @param params [Hash] Request params
      # @return [Hash, nil]
      def sanitize_rest_params(params)
        return nil if params.nil? || !params.is_a?(Hash) || params.empty?

        # Remove Rails internal params if present
        params = params.except("controller", "action", "format", "authenticity_token")
        return nil if params.empty?

        params.each_with_object({}) do |(key, value), result|
          result[key] = sanitize_variable_value(key, value)
        end
      rescue => e
        log_error("sanitize_rest_params failed: #{e.message}")
        nil
      end

      # Check if path indicates a GraphQL endpoint
      # @param path [String] Request path
      # @return [Boolean]
      def graphql_path?(path)
        return false if path.nil?
        path == "/graphql" || path.start_with?("/graphql/")
      end

      # Check if request is a GraphQL POST request
      # Used to determine if we should inspect response body for errors
      # @param env [Hash] Rack environment
      # @return [Boolean]
      def graphql_request?(env)
        env["REQUEST_METHOD"] == "POST" && graphql_path?(env["PATH_INFO"])
      rescue => e
        log_error("graphql_request? failed: #{e.message}")
        false
      end

      # Maximum response body size to read for GraphQL error extraction (32KB)
      # GraphQL error responses are small JSON - if it's bigger, skip it
      MAX_GRAPHQL_RESPONSE_SIZE = 32 * 1024

      # PARANOID-SAFE GraphQL error extraction
      #
      # This method extracts GraphQL errors from the response body with
      # ABSOLUTE SAFETY guarantees. It will return nil on ANY doubt.
      #
      # SAFETY RULES (non-negotiable):
      # 1. NEVER call behavior-inducing methods on the body (.each, .read, .close, .to_a, etc.)
      # 2. NEVER reassign or replace the body
      # 3. ONLY use instance_variable_get to peek inside wrappers (read-only memory access)
      # 4. ONLY proceed if we find a plain Array of plain Strings
      # 5. ONLY proceed if total size is small
      # 6. On ANY exception, return nil immediately
      #
      # WHY SO PARANOID:
      # - This gem runs in production apps we don't control
      # - Response bodies can be: streaming, file-backed, lazy, proxied, etc.
      # - Calling methods on unknown body types can: hang, crash, corrupt, consume memory
      # - We'd rather miss some GraphQL errors than risk breaking ANY app
      #
      # WHAT WE DO:
      # - Use instance_variable_get (pure memory read, zero side effects) to peek inside wrappers
      # - Rack::BodyProxy stores the real body in @body instance variable
      # - ActionDispatch::Response::RackBody stores it in @response.@stream.@buf or similar
      # - We try to find the underlying Array without calling any methods
      #
      # @param body [Object] Rack response body - WE DO NOT TOUCH THIS (except instance_variable_get)
      # @return [String, nil] Error message or nil (nil = safe default)
      def safely_read_graphql_errors(body)
        # Try to extract the underlying array from the body
        # This uses ONLY instance_variable_get which is a pure memory read
        inner_array = extract_inner_array_safely(body)

        # If we couldn't find a plain Array, give up
        return nil unless inner_array

        # Now validate and read the array
        read_array_for_graphql_errors(inner_array)
      rescue
        # ANY exception = return nil, never crash, never log (logging might fail too)
        # We intentionally swallow everything here for maximum safety
        nil
      end

      # Extract the underlying Array from a response body using ONLY instance_variable_get
      #
      # instance_variable_get is a PURE MEMORY READ - it cannot:
      # - Trigger any callbacks or side effects
      # - Cause network IO
      # - Modify any state
      # - Raise exceptions (except if the object is frozen in weird ways)
      #
      # This makes it safe to peek inside wrapper objects.
      #
      # @param body [Object] Response body (might be Array, BodyProxy, or other wrapper)
      # @return [Array, nil] The underlying Array if found and safe, nil otherwise
      def extract_inner_array_safely(body)
        # CASE 1: Already a plain Array - perfect
        return body if body.class == Array

        # CASE 2: Rack::BodyProxy - wraps body in @body instance variable
        # This is the most common case in Rails
        if body.class.name == "Rack::BodyProxy"
          inner = body.instance_variable_get(:@body)
          return inner if inner.class == Array
          # If @body is also wrapped, don't go deeper - too risky
          return nil
        end

        # CASE 3: ActionDispatch::Response::RackBody
        # Structure: RackBody -> @response -> @stream -> @buf (Array)
        # This is complex, let's try one level only
        if body.class.name == "ActionDispatch::Response::RackBody"
          response = body.instance_variable_get(:@response)
          return nil unless response

          # Try to get the stream
          stream = response.instance_variable_get(:@stream)
          return nil unless stream

          # Try to get the buffer
          buf = stream.instance_variable_get(:@buf)
          return buf if buf.class == Array

          return nil
        end

        # CASE 4: Unknown wrapper type - don't risk it
        # We only handle known, well-understood wrapper types
        nil
      rescue
        # Any error during extraction = give up safely
        nil
      end

      # Read an Array for GraphQL errors with full validation
      #
      # PRECONDITION: inner_array.class == Array (verified by caller)
      #
      # @param inner_array [Array] The array to read (must be exactly Array class)
      # @return [String, nil] Error message or nil
      def read_array_for_graphql_errors(inner_array)
        # SAFETY CHECK 1: Must not be empty
        return nil if inner_array.empty?

        # SAFETY CHECK 2: Every element must be exactly String class
        # We check class == String, not is_a?(String), to reject subclasses
        # that might have overridden methods
        return nil unless inner_array.all? { |part| part.class == String }

        # SAFETY CHECK 3: Calculate total size
        # Array#sum with a block is safe - it just iterates our verified Array
        total_size = inner_array.sum { |part| part.bytesize }

        # SAFETY CHECK 4: Must be small (error responses are small)
        return nil if total_size > MAX_GRAPHQL_RESPONSE_SIZE

        # SAFE TO PROCEED: inner_array is a plain Array of plain Strings, small size
        # Array#join creates a NEW string, does not modify the array
        response_text = inner_array.join

        # Parse and extract errors
        parse_graphql_errors(response_text)
      rescue
        # Any error = return nil safely
        nil
      end

      # Parse GraphQL response JSON and extract error messages
      #
      # This only receives a String that we created via join, so it's safe.
      #
      # @param response_text [String] Response body text (our copy, not original)
      # @return [String, nil] Combined error message or nil if no errors
      def parse_graphql_errors(response_text)
        return nil if response_text.nil? || response_text.empty?

        parsed = JSON.parse(response_text)
        return nil unless parsed.class == Hash  # Exact class check

        errors = parsed["errors"]
        return nil unless errors.class == Array && !errors.empty?  # Exact class check

        # Extract message from each error object
        messages = errors.map { |err| err["message"] if err.class == Hash }.compact
        return nil if messages.empty?

        # Return single message or join multiple with semicolon
        messages.size == 1 ? messages.first : messages.join("; ")
      rescue JSON::ParserError
        # Not valid JSON, skip
        nil
      rescue
        # Any other error, skip silently
        nil
      end

      # Check if GraphQL operation should be excluded from capture
      # Supports exact match and prefix match (patterns ending with *)
      # @param operation_name [String, nil] GraphQL operation name
      # @return [Boolean]
      def excluded_graphql_operation?(operation_name)
        return false if operation_name.nil? || operation_name.empty?

        excluded = EzLogsAgent.configuration.all_excluded_graphql_operations
        excluded.any? { |pattern| graphql_operation_matches?(operation_name, pattern) }
      rescue => e
        log_error("excluded_graphql_operation? failed: #{e.message}")
        false # Defensive: don't exclude if check fails
      end

      # Check if operation name matches an exclusion pattern
      # @param name [String] Operation name
      # @param pattern [String] Exclusion pattern (exact or with * for prefix)
      # @return [Boolean]
      def graphql_operation_matches?(name, pattern)
        if pattern.end_with?("*")
          # Prefix match: "__*" matches "__schema", "__type", etc.
          name.start_with?(pattern.chomp("*"))
        else
          # Exact match
          name == pattern
        end
      end

      # Read request body from Rack env
      # @param env [Hash] Rack environment
      # @return [String, nil] Request body or nil
      def read_request_body(env)
        input = env["rack.input"]
        return nil unless input

        # Read and rewind for downstream middleware/app
        body = input.read
        input.rewind
        body
      rescue => e
        log_error("read_request_body failed: #{e.message}")
        nil
      end

      # Infer GraphQL operation type from query string
      # @param query [String, nil] GraphQL query string
      # @return [String, nil] "query", "mutation", or "subscription"
      def infer_operation_type(query)
        return nil if query.nil? || query.empty?

        # Simple pattern matching for operation type
        # Use \A anchor (start of string) not ^ (start of line) to avoid
        # matching field names like "subscription" in multiline queries
        case query.strip
        when /\A\s*mutation/i
          "mutation"
        when /\A\s*subscription/i
          "subscription"
        when /\A\s*query/i, /\A\s*\{/
          "query"
        else
          nil
        end
      rescue => e
        log_error("infer_operation_type failed: #{e.message}")
        nil
      end

      # Infer GraphQL operation type from operation name
      # Uses naming conventions: Get*, Fetch*, List*, Find* are queries
      # @param operation_name [String, nil] GraphQL operation name
      # @return [String, nil] "query", "mutation", or nil
      def infer_operation_type_from_name(operation_name)
        return nil if operation_name.nil? || operation_name.empty?

        # Query prefixes (read operations)
        query_prefixes = %w[Get Fetch List Find Load Search Query]

        # Check if operation name starts with a query prefix
        if query_prefixes.any? { |prefix| operation_name.start_with?(prefix) }
          return "query"
        end

        # Mutation prefixes (write operations)
        mutation_prefixes = %w[Create Update Delete Remove Add Set Upsert]

        if mutation_prefixes.any? { |prefix| operation_name.start_with?(prefix) }
          return "mutation"
        end

        # Can't determine from name alone
        nil
      rescue => e
        log_error("infer_operation_type_from_name failed: #{e.message}")
        nil
      end

      # Extract GraphQL operation name from query string
      # Parses the operation name from queries like:
      #   "query blueprints($ids: [ID!]) { ... }" → "blueprints"
      #   "mutation CreateUser($input: CreateUserInput!) { ... }" → "CreateUser"
      #   "query { users { id } }" → nil (anonymous query)
      #   "{ users { id } }" → nil (shorthand query)
      #
      # @param query [String, nil] GraphQL query string
      # @return [String, nil] Operation name or nil if not found/anonymous
      def extract_operation_name_from_query(query)
        return nil if query.nil? || query.empty?

        # Match: query/mutation/subscription followed by optional whitespace,
        # then an operation name (identifier), then either ( or { or whitespace
        # The operation name is a GraphQL identifier: [_A-Za-z][_0-9A-Za-z]*
        match = query.match(/\A\s*(?:query|mutation|subscription)\s+([_A-Za-z][_0-9A-Za-z]*)/i)
        return match[1] if match

        # No named operation found (anonymous query or shorthand syntax)
        nil
      rescue => e
        log_error("extract_operation_name_from_query failed: #{e.message}")
        nil
      end

      # Sanitization (sensitive-key filtering, nesting depth limit,
      # array-size truncation) lives in `EzLogsAgent::Sanitizer` so the
      # same rules apply to HTTP params, GraphQL variables, and
      # ActiveJob/Sidekiq arguments. These helpers are thin wrappers
      # around that shared module.
      def sanitize_graphql_variables(variables)
        return nil if variables.nil?
        return nil unless variables.is_a?(Hash)
        return nil if variables.empty?

        variables.each_with_object({}) do |(key, value), result|
          result[key] = EzLogsAgent::Sanitizer.sanitize_value(key, value)
        end
      rescue => e
        log_error("sanitize_graphql_variables failed: #{e.message}")
        nil
      end

      def sanitize_variable_value(key, value, depth = 0)
        EzLogsAgent::Sanitizer.sanitize_value(key, value, depth)
      end

      # Extract context hash including actor if available
      # @return [Hash, nil]
      def extract_context
        context = {}

        # Include actor if set (via actor_from_request hook or with_actor)
        actor = EzLogsAgent::Actor.current
        context[:actor] = actor if actor

        # Include legacy user_id if present in RequestStore
        # (for backward compatibility)
        if defined?(RequestStore) && RequestStore.store[:user_id]
          context[:user_id] = RequestStore.store[:user_id]
        end

        context.empty? ? nil : context
      rescue => e
        log_error("extract_context failed: #{e.message}")
        nil
      end

      # Extract actor using configured hook, then apply User-Agent based
      # `actor_kind` detection. The customer's hook resolves WHO the
      # actor is (id/label); the UA detector resolves WHAT KIND. If the
      # hook returns nothing but the UA identifies a known LLM client,
      # synthesize a minimal agent actor so the Pulse Agent view has
      # something to anchor on.
      # @param env [Hash] Rack environment
      # @return [void]
      def extract_and_set_actor(env)
        hook = EzLogsAgent.configuration.actor_from_request
        controller = env["action_controller.instance"]

        hook_actor = nil
        if hook.respond_to?(:call)
          hook_actor = hook.call(env, controller)
        end

        ua_match = EzLogsAgent::UserAgentDetector.classify(env["HTTP_USER_AGENT"])

        final_actor = merge_actor_with_ua(hook_actor, ua_match)
        EzLogsAgent::Actor.current = final_actor if final_actor
      rescue => e
        log_error("extract_and_set_actor failed: #{e.message}")
        # Continue without actor - better than crashing
      end

      # Merge the hook's actor with a UA-detected agent classification.
      #
      # Rules (matches the Phase 8 Week 1 plan):
      # - Hook actor present, no UA match -> hook actor unchanged.
      # - Hook actor present, UA match    -> hook id/label preserved;
      #   kind defaults to UA's kind only when the hook didn't supply one.
      # - No hook actor, UA match         -> synthesize an agent actor.
      # - No hook actor, no UA match      -> nil (unknown provenance).
      def merge_actor_with_ua(hook_actor, ua_match)
        if hook_actor && hook_actor.respond_to?(:[])
          return hook_actor if ua_match.nil?

          existing_kind = hook_actor[:kind] || hook_actor["kind"]
          return hook_actor if existing_kind && !existing_kind.to_s.empty?

          merged = hook_actor.dup
          merged[:kind] = ua_match[:kind]
          merged
        elsif ua_match
          {
            id: ua_match[:suggested_id],
            label: ua_match[:label],
            kind: ua_match[:kind]
          }
        end
      end

      # Clear actor context after request completes
      # @return [void]
      def clear_actor
        EzLogsAgent::Actor.clear
      rescue => e
        log_error("clear_actor failed: #{e.message}")
        # Ignore - cleanup failure is not critical
      end

      # Setup correlation context for this request
      # Generates a new correlation_id and stores it in RequestStore
      # @return [void]
      def setup_correlation
        EzLogsAgent::Correlation.current = EzLogsAgent::Correlation.generate
      rescue => e
        log_error("setup_correlation failed: #{e.message}")
        # Continue without correlation - better than crashing
      end

      # Clear correlation context after request completes
      # @return [void]
      def clear_correlation
        EzLogsAgent::Correlation.clear
      rescue => e
        log_error("clear_correlation failed: #{e.message}")
        # Ignore - cleanup failure is not critical
      end

      # Get current correlation ID from Correlation module
      # @return [String, nil]
      def current_correlation_id
        EzLogsAgent::Correlation.current
      rescue => e
        log_error("current_correlation_id failed: #{e.message}")
        nil
      end

      # Determine outcome and error_message based on status, exception, and GraphQL errors
      #
      # Outcome rules (from user's perspective):
      # - Exception raised = failure (system error)
      # - 4xx status = failure (user's intent was not fulfilled)
      # - 5xx status = failure (server error)
      # - GraphQL errors in response = failure (business-level error)
      # - 2xx/3xx status = success
      # - nil status = success (no response yet, optimistic)
      #
      # @param status [Integer, nil] HTTP status code
      # @param exception [Exception, nil] Exception if raised
      # @param graphql_response_errors [String, nil] GraphQL errors from response body
      # @return [Array<String, String|nil>] [outcome, error_message]
      def determine_outcome(status, exception, graphql_response_errors = nil)
        # Exception raised = failure
        if exception
          return ["failure", "#{exception.class}: #{exception.message}"]
        end

        # 4xx/5xx = failure (user's intent was not fulfilled)
        if status && status >= 400
          return ["failure", "HTTP #{status}"]
        end

        # GraphQL errors in response body = failure
        # This catches authorization errors, validation errors, etc. that return HTTP 200
        if graphql_response_errors
          return ["failure", graphql_response_errors]
        end

        # 2xx, 3xx, nil = success
        ["success", nil]
      end

      # Get current time in milliseconds
      # @return [Integer]
      def current_time_ms
        (Time.now.to_f * 1000).to_i
      end

      # Log error (defensive, never crashes)
      # @param message [String]
      # @return [void]
      def log_error(message)
        EzLogsAgent::Logger.error("[HttpRequest] #{message}")
      rescue
        # Logging must never crash middleware
      end
    end
  end
end
