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

    # Clear the current correlation ID
    #
    # @return [void]
    def self.clear
      RequestStore.store.delete(STORE_KEY)
    end
  end
end
