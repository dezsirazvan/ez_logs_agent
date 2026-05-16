# frozen_string_literal: true

module EzLogsAgent
  module Capturers
    class JobCapturer
      # Sidekiq client middleware that propagates correlation_id
      # from the current request context into enqueued job payloads.
      #
      # This middleware runs at enqueue-time (when a job is scheduled),
      # NOT at execution-time.
      #
      # == Behavior
      #
      # - Reads EzLogsAgent::Correlation.current
      # - If present, injects it into job["correlation_id"]
      # - Never overwrites existing job["correlation_id"]
      # - Never raises exceptions
      # - Always yields to next middleware
      #
      # == Registration
      #
      # Note: This middleware is automatically registered by Railtie.
      # Users do NOT need to manually configure it.
      #
      # For manual setup (if not using Rails), add to your Sidekiq initializer:
      #
      #   Sidekiq.configure_client do |config|
      #     config.client_middleware do |chain|
      #       chain.add EzLogsAgent::Capturers::JobCapturer::ClientMiddleware
      #     end
      #   end
      #
      class ClientMiddleware
        # Sidekiq client middleware hook.
        #
        # @param worker_class [Class] The worker class being enqueued
        # @param job [Hash] The Sidekiq job payload (mutable)
        # @param queue [String] The queue name
        # @param redis_pool [ConnectionPool] Sidekiq's Redis connection pool
        # @yield Passes control to the next middleware in the chain
        # @return [void]
        def call(worker_class, job, queue, redis_pool)
          # Defensive: ensure job is a Hash
          return yield unless job.is_a?(Hash)

          begin
            # Read current correlation_id from context
            correlation_id = EzLogsAgent::Correlation.current

            # Only inject if:
            # 1. correlation_id is present and not empty
            # 2. job doesn't already have one
            if correlation_id && correlation_id.respond_to?(:empty?) && !correlation_id.empty? && !job.key?("correlation_id")
              job["correlation_id"] = correlation_id
            end
          rescue StandardError => e
            # Never crash the host application during correlation injection
            # Log error, then continue
            EzLogsAgent::Logger.error("[JobCapturer::ClientMiddleware] Error during correlation injection: #{e.class} - #{e.message}")
          end

          # Always yield to next middleware
          yield
        end
      end

      # Sidekiq server middleware that captures background job execution
      # as background_job events.
      #
      # This middleware runs at execution-time (when the job runs),
      # NOT at enqueue-time.
      #
      # == Behavior
      #
      # - Restores correlation_id from job["correlation_id"] (or generates new one)
      # - Measures job execution duration
      # - Captures success or failure outcome
      # - Re-raises exceptions after capturing failure
      # - Always clears correlation_id in ensure block
      # - Respects capture_jobs configuration flag
      #
      # == Registration
      #
      # Note: This middleware is automatically registered by Railtie.
      # Users do NOT need to manually configure it.
      #
      # For manual setup (if not using Rails), add to your Sidekiq initializer:
      #
      #   Sidekiq.configure_server do |config|
      #     config.server_middleware do |chain|
      #       chain.add EzLogsAgent::Capturers::JobCapturer::ServerMiddleware
      #     end
      #   end
      #
      class ServerMiddleware
        # Sidekiq server middleware hook.
        #
        # @param worker [Object] The worker instance executing the job
        # @param job [Hash] The Sidekiq job payload
        # @param queue [String] The queue name
        # @yield Executes the job
        # @return [void]
        def call(worker, job, queue)
          # Skip capture if disabled
          return yield unless EzLogsAgent.configuration.capture_jobs

          # Skip excluded job classes (health checks, infrastructure jobs).
          # Match against the underlying ActiveJob class too, not just the wrapper.
          if excluded_job_class?(worker, job)
            EzLogsAgent::Logger.debug("[JobCapturer::ServerMiddleware] Skipping capture (excluded job class: #{resolve_job_class(worker, job)})")
            return yield
          end

          # Restore correlation_id from job payload (or generate new one)
          correlation_id = job["correlation_id"] || EzLogsAgent::Correlation.generate
          EzLogsAgent::Correlation.current = correlation_id

          # Measure execution time
          start_time = Time.now
          result = yield
          duration_ms = ((Time.now - start_time) * 1000).to_i

          # Capture success event
          capture_success(worker, job, queue, correlation_id, duration_ms, start_time)

          result
        rescue StandardError => error
          # Capture failure event, then re-raise
          capture_failure(worker, job, queue, correlation_id, error, start_time)
          raise
        ensure
          # Always clear correlation_id
          EzLogsAgent::Correlation.clear
        end

        private

        # Captures successful job execution.
        #
        # @param worker [Object] The worker instance
        # @param job [Hash] The Sidekiq job payload
        # @param queue [String] The queue name
        # @param correlation_id [String] The correlation ID
        # @param duration_ms [Integer] Job execution duration in milliseconds
        # @param start_time [Time] Job start time
        # @return [void]
        def capture_success(worker, job, queue, correlation_id, duration_ms, start_time)
          event = EzLogsAgent::EventBuilder.build(
            source_type: :background_job,
            source_data: extract_job_data(worker, job, queue),
            outcome: :success,
            correlation_id: correlation_id,
            duration_ms: duration_ms,
            timestamp: start_time
          )

          EzLogsAgent::Buffer.push(event)
        rescue StandardError => e
          # Defensive: never crash the host application during event capture
          EzLogsAgent::Logger.error("[JobCapturer::ServerMiddleware] Failed to capture success event: #{e.class} - #{e.message}")
        end

        # Captures failed job execution.
        #
        # @param worker [Object] The worker instance
        # @param job [Hash] The Sidekiq job payload
        # @param queue [String] The queue name
        # @param correlation_id [String] The correlation ID
        # @param error [StandardError] The error that caused the failure
        # @param start_time [Time] Job start time
        # @return [void]
        def capture_failure(worker, job, queue, correlation_id, error, start_time)
          event = EzLogsAgent::EventBuilder.build(
            source_type: :background_job,
            source_data: extract_job_data(worker, job, queue),
            outcome: :failure,
            correlation_id: correlation_id,
            error_message: "#{error.class}: #{error.message}",
            timestamp: start_time
          )

          EzLogsAgent::Buffer.push(event)
        rescue StandardError => e
          # Defensive: never crash the host application during event capture
          EzLogsAgent::Logger.error("[JobCapturer::ServerMiddleware] Failed to capture failure event: #{e.class} - #{e.message}")
        end

        # Extracts relevant job data for event source_data.
        #
        # When the worker is the ActiveJob+Sidekiq wrapper, we surface the
        # underlying ActiveJob class name (e.g., "ChargeCardJob") rather
        # than the wrapper class. This mirrors how Sidekiq itself resolves
        # the display class — see Sidekiq::JobLogger and Sidekiq::JobUtil:
        #
        #   job_hash["display_class"] || job_hash["wrapped"] || job_hash["class"]
        #
        # @param worker [Object] The worker instance
        # @param job [Hash] The Sidekiq job payload
        # @param queue [String] The queue name
        # @return [Hash] Job metadata for source_data
        def extract_job_data(worker, job, queue)
          {
            job_class: resolve_job_class(worker, job),
            job_id: job["jid"],
            queue: queue,
            retry_count: job["retry_count"],
            arguments: extract_arguments(job)
          }.compact
        end

        # Sanitize the job's arguments. Sidekiq stores them in
        # `job["args"]`. When the job is wrapped by ActiveJob, the
        # outer args is a single-element array containing an
        # ActiveJob payload whose `arguments` key holds the actual
        # user-passed args — unwrap that so the dashboard shows the
        # arguments the user wrote, not the ActiveJob plumbing.
        def extract_arguments(job)
          raw = job["args"]
          return nil if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)

          # ActiveJob+Sidekiq: args == [{"job_class"=>..., "arguments"=>[...], ...}]
          if raw.is_a?(Array) && raw.size == 1 && raw.first.is_a?(Hash) && raw.first.key?("arguments")
            raw = raw.first["arguments"]
            return nil if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)
          end

          EzLogsAgent::Sanitizer.sanitize_args(raw)
        rescue StandardError => e
          EzLogsAgent::Logger.debug("[JobCapturer::ServerMiddleware] argument extraction failed: #{e.class}: #{e.message}")
          nil
        end

        # Resolves the human-meaningful job class name, unwrapping the
        # ActiveJob+Sidekiq adapter when present.
        #
        # @param worker [Object] The worker instance Sidekiq is running
        # @param job [Hash] The Sidekiq job payload
        # @return [String] The class name to record on the event
        def resolve_job_class(worker, job)
          job["display_class"] || job["wrapped"] || worker.class.name
        end

        # Checks if worker class is in the excluded list.
        #
        # Exclusion is matched against the same name that lands in
        # source_data, so users can list either the Sidekiq worker class
        # or the underlying ActiveJob class — whichever they actually own.
        #
        # @param worker [Object] The worker instance
        # @param job [Hash] The Sidekiq job payload (optional; defaults to {})
        # @return [Boolean] true if excluded, false otherwise
        def excluded_job_class?(worker, job = {})
          excluded = EzLogsAgent.configuration.all_excluded_job_classes
          [worker.class.name, job["wrapped"], job["display_class"]].compact.any? { |name| excluded.include?(name) }
        rescue StandardError
          false
        end
      end
    end
  end
end
