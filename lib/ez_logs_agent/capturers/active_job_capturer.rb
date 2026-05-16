# frozen_string_literal: true

module EzLogsAgent
  module Capturers
    # ActiveJob hooks for correlation propagation and job execution capture.
    #
    # This capturer provides first-class ActiveJob support with two responsibilities:
    #
    # 1. **Enqueue-Time (Correlation Propagation)**:
    #    - Uses `before_enqueue` callback to inject correlation_id into job
    #    - Preserves causal chain: HTTP → Job → Job
    #
    # 2. **Execution-Time (Job Capture)**:
    #    - Uses `around_perform` callback to capture job execution as background_job events
    #    - Restores correlation_id from job
    #    - Measures duration and captures success/failure outcome
    #
    # == Serialization Support
    #
    # ActiveJob's metadata hash is NOT automatically serialized. This capturer
    # overrides `serialize` and `deserialize` to persist the correlation_id
    # across job serialization (required for Async adapter and other adapters
    # that serialize jobs).
    #
    # == Sidekiq Adapter Detection
    #
    # If the job's queue adapter is Sidekiq, this capturer:
    # - STILL propagates correlation at enqueue-time
    # - SKIPS execution capture (defers to Sidekiq server middleware)
    #
    # This prevents double events when Sidekiq is the adapter.
    #
    # == Installation
    #
    # This capturer is automatically installed by Railtie when ActiveJob
    # is detected and `capture_jobs = true`.
    #
    # For manual installation (if not using Rails):
    #
    #   EzLogsAgent::Capturers::ActiveJobCapturer.install
    #
    class ActiveJobCapturer
      @serialization_installed = false

      class << self
        # Installs ActiveJob hooks for correlation propagation and job capture.
        #
        # This method is idempotent and can be called multiple times safely.
        #
        # @return [void]
        def install
          return unless defined?(ActiveJob)

          install_serialization_hooks unless @serialization_installed

          ActiveJob::Base.before_enqueue do |job|
            ActiveJobCapturer.propagate_correlation(job)
          end

          ActiveJob::Base.around_perform do |job, block|
            ActiveJobCapturer.capture_execution(job, block)
          end

          EzLogsAgent::Logger.debug("[ActiveJobCapturer] Hooks installed")
        rescue StandardError => e
          EzLogsAgent::Logger.error("[ActiveJobCapturer] Installation failed: #{e.class} - #{e.message}")
        end

        # Propagates correlation_id from current context into job.
        #
        # Runs at enqueue-time (when job is scheduled).
        # Stores correlation in `ezlogs_correlation_id` attribute which
        # survives serialization/deserialization.
        #
        # @param job [ActiveJob::Base] The job being enqueued
        # @return [void]
        def propagate_correlation(job)
          correlation_id = EzLogsAgent::Correlation.current
          return unless correlation_id && !correlation_id.empty?

          job.ezlogs_correlation_id = correlation_id
        rescue StandardError => e
          EzLogsAgent::Logger.error("[ActiveJobCapturer] Correlation propagation failed: #{e.class} - #{e.message}")
        end

        # Captures job execution as a background_job event.
        #
        # Runs at execution-time (when job executes).
        # Skips capture if job uses Sidekiq adapter (prevents double events).
        #
        # IMPORTANT: When jobs run inline (Async adapter, perform_now, test adapter),
        # they execute in the same thread as the caller (HTTP request or parent job).
        # We must save and restore the previous correlation to avoid clearing the
        # outer context's correlation. This applies to:
        # - Development with Async adapter
        # - Production with perform_now calls
        # - Test environments
        # - Any synchronous job execution
        #
        # @param job [ActiveJob::Base] The job being executed
        # @param block [Proc] The job execution block
        # @return [Object] The result of the job execution
        def capture_execution(job, block)
          return block.call unless EzLogsAgent.configuration.capture_jobs

          if sidekiq_adapter?(job)
            EzLogsAgent::Logger.debug("[ActiveJobCapturer] Skipping capture (Sidekiq adapter)")
            return block.call
          end

          if excluded_job_class?(job)
            EzLogsAgent::Logger.debug("[ActiveJobCapturer] Skipping capture (excluded job class: #{job.class.name})")
            return block.call
          end

          # Save the previous correlation (from HTTP middleware or parent job)
          # so we can restore it after the job completes
          previous_correlation = EzLogsAgent::Correlation.current

          # Use job's propagated correlation, fall back to current context, or generate new
          correlation_id = extract_correlation(job) || previous_correlation || EzLogsAgent::Correlation.generate
          EzLogsAgent::Correlation.current = correlation_id

          start_time = Time.now
          result = block.call
          duration_ms = ((Time.now - start_time) * 1000).to_i

          capture_success(job, correlation_id, duration_ms, start_time)
          result
        rescue StandardError => error
          capture_failure(job, correlation_id, error, start_time)
          raise
        ensure
          # Restore previous correlation instead of unconditionally clearing.
          # This is critical for inline jobs that run in the same thread as the caller.
          if previous_correlation
            EzLogsAgent::Correlation.current = previous_correlation
          else
            EzLogsAgent::Correlation.clear
          end
        end

        private

        # Installs serialization hooks on ActiveJob::Base to persist correlation_id
        # across job serialization/deserialization.
        #
        # This is required because ActiveJob's metadata hash is NOT automatically
        # serialized. We override `serialize` and `deserialize` to include our
        # correlation_id in the job data.
        #
        # @return [void]
        def install_serialization_hooks
          return if @serialization_installed

          ActiveJob::Base.class_eval do
            attr_accessor :ezlogs_correlation_id
          end

          ActiveJob::Base.prepend(Module.new do
            def serialize
              super.merge("ezlogs_correlation_id" => @ezlogs_correlation_id)
            end

            def deserialize(job_data)
              super
              @ezlogs_correlation_id = job_data["ezlogs_correlation_id"]
            end
          end)

          @serialization_installed = true
          EzLogsAgent::Logger.debug("[ActiveJobCapturer] Serialization hooks installed")
        rescue StandardError => e
          EzLogsAgent::Logger.error("[ActiveJobCapturer] Failed to install serialization hooks: #{e.class} - #{e.message}")
        end

        # Checks if job uses Sidekiq adapter.
        #
        # @param job [ActiveJob::Base] The job instance
        # @return [Boolean] true if Sidekiq adapter, false otherwise
        def sidekiq_adapter?(job)
          return false unless defined?(ActiveJob::QueueAdapters::SidekiqAdapter)

          job.class.queue_adapter.is_a?(ActiveJob::QueueAdapters::SidekiqAdapter)
        rescue StandardError
          false
        end

        # Checks if job class is in the excluded list.
        #
        # @param job [ActiveJob::Base] The job instance
        # @return [Boolean] true if excluded, false otherwise
        def excluded_job_class?(job)
          job_class_name = job.class.name
          EzLogsAgent.configuration.all_excluded_job_classes.include?(job_class_name)
        rescue StandardError
          false
        end

        # Extracts correlation_id from job.
        #
        # @param job [ActiveJob::Base] The job instance
        # @return [String, nil] The correlation_id if present
        def extract_correlation(job)
          return nil unless job.respond_to?(:ezlogs_correlation_id)

          correlation = job.ezlogs_correlation_id
          correlation if correlation && !correlation.empty?
        rescue StandardError
          nil
        end

        # Captures successful job execution.
        #
        # @param job [ActiveJob::Base] The job instance
        # @param correlation_id [String] The correlation ID
        # @param duration_ms [Integer] Job execution duration in milliseconds
        # @param start_time [Time] Job start time
        # @return [void]
        def capture_success(job, correlation_id, duration_ms, start_time)
          event = EzLogsAgent::EventBuilder.build(
            source_type: :background_job,
            source_data: extract_job_data(job),
            outcome: :success,
            correlation_id: correlation_id,
            duration_ms: duration_ms,
            timestamp: start_time
          )

          EzLogsAgent::Buffer.push(event)
        rescue StandardError => e
          EzLogsAgent::Logger.error("[ActiveJobCapturer] Failed to capture success event: #{e.class} - #{e.message}")
        end

        # Captures failed job execution.
        #
        # @param job [ActiveJob::Base] The job instance
        # @param correlation_id [String] The correlation ID
        # @param error [StandardError] The error that caused the failure
        # @param start_time [Time] Job start time
        # @return [void]
        def capture_failure(job, correlation_id, error, start_time)
          event = EzLogsAgent::EventBuilder.build(
            source_type: :background_job,
            source_data: extract_job_data(job),
            outcome: :failure,
            correlation_id: correlation_id,
            error_message: "#{error.class}: #{error.message}",
            timestamp: start_time
          )

          EzLogsAgent::Buffer.push(event)
        rescue StandardError => e
          EzLogsAgent::Logger.error("[ActiveJobCapturer] Failed to capture failure event: #{e.class} - #{e.message}")
        end

        # Extracts relevant job data for event source_data.
        #
        # @param job [ActiveJob::Base] The job instance
        # @return [Hash] Job metadata for source_data
        def extract_job_data(job)
          {
            job_class: job.class.name,
            queue: job.queue_name,
            arguments: extract_arguments(job)
          }.compact
        end

        # Pull sanitized arguments off the job. We prefer
        # `job.serialize["arguments"]` (the JSON-safe form that survives
        # Redis/Sidekiq) over `job.arguments` (live Ruby objects, can
        # include AR records). Sanitizer collapses non-primitive top-
        # level values to "[Object]" so giant graphs never ship.
        #
        # Returns nil when no arguments are present so `.compact` drops
        # the field entirely — keeps the source_data clean for jobs
        # like health-checks that take no args.
        def extract_arguments(job)
          serialized = serialize_safely(job)
          raw = serialized && serialized["arguments"]
          raw = job.arguments if raw.nil? && job.respond_to?(:arguments)
          return nil if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)

          EzLogsAgent::Sanitizer.sanitize_args(raw)
        rescue StandardError => e
          EzLogsAgent::Logger.debug("[ActiveJobCapturer] argument extraction failed: #{e.class}: #{e.message}")
          nil
        end

        def serialize_safely(job)
          return nil unless job.respond_to?(:serialize)

          job.serialize
        rescue StandardError
          nil
        end
      end
    end
  end
end
