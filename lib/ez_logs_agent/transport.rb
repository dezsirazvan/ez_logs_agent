# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module EzLogsAgent
  # HTTP Transport Client
  #
  # Lowest-level component that sends events to the EzLogs server.
  # Performs a single HTTP POST request with no retries or backoff.
  #
  # Responsibilities:
  # - Serialize events to JSON
  # - POST to server endpoint
  # - Return :success or :failure
  #
  # Does NOT:
  # - Retry failed requests
  # - Implement backoff logic
  # - Read from Buffer
  # - Call Buffer.flush
  # - Raise exceptions to host app
  class Transport
    class << self
      # Send events to the server
      #
      # @param events [Array<Hash>] Array of event hashes
      # @param timeout [Numeric, nil] open/read/write timeout override (seconds)
      # @return [Symbol] :success if 2xx, :rejected for a refusal that can't succeed on retry (4xx
      #   other than 408 and 429), :failure otherwise
      def send(events, timeout: nil)
        return :success if events.nil? || events.empty?

        response = post_events(events, timeout)
        classify_response(response)
      rescue => error
        Logger.error("[Transport] send failed: #{error.class} - #{error.message}")
        :failure
      end

      MAX_BATCH_BYTES = 1_000_000

      # Events split into posts of at most about 1 MB (the server refuses a post over 5 MB, and with it
      # every event inside): a busy moment sends several posts, never one refused whole.
      def batches(events)
        return [] if events.nil? || events.empty?

        result = [[]]
        size = 0
        events.each do |event|
          bytes = JSON.generate(event).bytesize
          if size + bytes > MAX_BATCH_BYTES && result.last.any?
            result << []
            size = 0
          end
          result.last << event
          size += bytes + 1
        end
        result
      rescue StandardError
        [events]
      end

      private

      def post_events(events, timeout)
        uri = build_uri
        http = build_http_client(uri, timeout)
        request = build_request(uri, events)

        http.request(request)
      end

      def build_uri
        server_url = EzLogsAgent.configuration.server_url
        raise "server_url not configured" if server_url.nil? || server_url.empty?

        URI.parse("#{server_url}/api/events")
      rescue => error
        raise "Invalid server_url: #{error.message}"
      end

      def build_http_client(uri, timeout = nil)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = timeout || 5
        http.read_timeout = timeout || 10
        http.write_timeout = timeout if timeout
        http
      end

      def build_request(uri, events)
        request = Net::HTTP::Post.new(uri.path)
        request["Content-Type"] = "application/json"

        token = EzLogsAgent.configuration.project_token
        request["Authorization"] = "Bearer #{token}" if token

        request.body = JSON.generate({ events: events })
        request
      end

      def classify_response(response)
        status = response.code.to_i

        if status >= 200 && status < 300
          Logger.debug("[Transport] send succeeded (#{status})")
          :success
        elsif status >= 400 && status < 500 && ![408, 429].include?(status)
          Logger.error("[Transport] send refused (#{status}), not retried")
          :rejected
        else
          Logger.error("[Transport] send failed (#{status})")
          :failure
        end
      end
    end
  end
end
