require "securerandom"
require "request_store"

module EzLogsAgent
  module Correlation
    STORE_KEY = :ez_logs_correlation_id

    # Generate a new unique correlation ID
    # Format: ezl_<timestamp_ms>_<random_hex_8>
    #
    # @return [String] A new correlation ID
    def self.generate
      timestamp_ms = (Time.now.to_f * 1000).to_i
      random_hex = SecureRandom.hex(4) # 8 chars
      "ezl_#{timestamp_ms}_#{random_hex}"
    end

    # Get the current correlation ID (or nil)
    #
    # @return [String, nil] The current correlation ID or nil if not set
    # Another service's call carries its correlation in X-Correlation-ID (the
    # agents' outgoing HTTP stamps it). The header can come from anyone, so it is
    # honoured only in the agents' own format and only when recent: joining
    # someone else's action would need their exact id (32 random bits) within
    # the hour. Same rule as the Next.js agent.
    HEADER_ENV = "HTTP_X_CORRELATION_ID"
    INBOUND_ID = /\Aezl_(\d{13})_[0-9a-f]{8}\z/
    INBOUND_MAX_AGE_MS = 60 * 60_000
    INBOUND_MAX_SKEW_MS = 5 * 60_000

    def self.trusted_inbound?(id)
      match = INBOUND_ID.match(id.to_s)
      return false unless match

      age = (Time.now.to_f * 1000).to_i - match[1].to_i
      age <= INBOUND_MAX_AGE_MS && age >= -INBOUND_MAX_SKEW_MS
    end

    # A job joins the action that enqueued it only while that action is recent (an hour): a job
    # delayed by days, or a retry days later, is its own action, never one dated days earlier and
    # done by whoever clicked then. Ids not in our format carry no time: kept.
    JOB_MAX_AGE_MS = 60 * 60_000

    def self.recent_for_job?(id)
      match = INBOUND_ID.match(id.to_s)
      return true unless match

      (Time.now.to_f * 1000).to_i - match[1].to_i <= JOB_MAX_AGE_MS
    end

    # The request's correlation id: the calling service's when trusted, else new.
    def self.for_request(env)
      inbound = env[HEADER_ENV]
      trusted_inbound?(inbound) ? inbound : generate
    end

    def self.current
      RequestStore.store[STORE_KEY]
    end

    # Set the current correlation ID
    #
    # @param value [String, nil] The correlation ID to store
    # @return [String, nil] The stored value
    def self.current=(value)
      RequestStore.store[STORE_KEY] = value
    end

    EXCLUDED_KEY = :ez_logs_excluded_request
    EXCLUDED_JOB_KEY = :ez_logs_excluded_job

    # While the app handles a request it excluded (config.excluded_paths), nothing its thread emits is
    # captured: its database writes and job enqueues would otherwise ship with no correlation, never
    # shown yet still stored. Restores the outer state, so a nested excluded call keeps the outer one.
    # shortcut: work on other threads, or in a streamed body after `call` returns, is still captured
    # uncorrelated; wrap the body / propagate the flag if that shows up in practice.
    # job: true for an excluded job, whose own inline jobs (perform_now) are housekeeping with it; a
    # job run inside an excluded request is still its own action (agent 0.2.6).
    def self.excluding(job: false)
      previous = RequestStore.store[EXCLUDED_KEY]
      previous_job = RequestStore.store[EXCLUDED_JOB_KEY]
      RequestStore.store[EXCLUDED_KEY] = true
      RequestStore.store[EXCLUDED_JOB_KEY] = true if job
      yield
    ensure
      { EXCLUDED_KEY => previous, EXCLUDED_JOB_KEY => previous_job }.each do |key, value|
        value.nil? ? RequestStore.store.delete(key) : RequestStore.store[key] = value
      end
    end

    def self.in_excluded_job?
      RequestStore.store[EXCLUDED_JOB_KEY] == true
    end

    def self.excluded?
      RequestStore.store[EXCLUDED_KEY] == true
    end

    # Clear the current correlation ID
    #
    # @return [void]
    def self.clear
      RequestStore.store.delete(STORE_KEY)
    end
  end
end
