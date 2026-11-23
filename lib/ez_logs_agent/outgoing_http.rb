# frozen_string_literal: true

require "net/http"
require "uri"

module EzLogsAgent
  # Stamps the current correlation id on outgoing HTTP calls as X-Correlation-ID,
  # so a call to another service running an EZLogs agent joins this action (that
  # agent honours it: Correlation.for_request). Covers Net::HTTP (and so
  # Faraday's default adapter, HTTParty, RestClient) and the `http` gem
  # (http.rb), which has its own sockets. Only when a correlation is current (a
  # captured request or job), never over a header the app set, never to the
  # EZLogs server. Fails open.
  module OutgoingHttp
    HEADER = "X-Correlation-ID"

    # The id to stamp on a call to host:port that has `existing` as its header, or nil.
    def self.id_for(host, port, existing)
      return nil if EzLogsAgent.configuration.propagate_correlation == false

      id = EzLogsAgent::Correlation.current
      id if id && existing.nil? && !ezlogs_server?(host, port)
    rescue StandardError
      nil
    end

    # Net::HTTP#request
    # The header is removed again after the call: an app that reuses its request
    # object must never send this action's id with a later one.
    #
    # Also records the call (OutboundCapture): a clock read before and after, the
    # status the response already holds, nothing else. Net::HTTP#request calls
    # itself once when it has to open the connection; only the outer call is
    # recorded (the request object is marked while it runs). With a block, the time
    # is to the response headers: the app reading a streamed body is not the call.
    module NetHttp
      def request(req, body = nil, &block)
        added = false
        capture = nil
        begin
          id = EzLogsAgent::OutgoingHttp.id_for(address, port, req[HEADER])
          (req[HEADER] = id) && (added = true) if id
          unless req.instance_variable_get(:@ez_logs_capturing)
            correlation = EzLogsAgent::OutboundCapture.correlation_for(address, port)
            if correlation
              req.instance_variable_set(:@ez_logs_capturing, true)
              capture = [correlation, EzLogsAgent::OutboundCapture.clock, nil, nil]
              if block
                inner = block
                # The status is read here too: the app may leave the block early (return, break).
                block = proc do |res|
                  capture[2] ||= EzLogsAgent::OutboundCapture.clock
                  capture[3] ||= res.code.to_i if res.respond_to?(:code)
                  inner.call(res)
                end
              end
            end
          end
        rescue StandardError
          capture = nil # never disturb the call
        end
        error = nil
        response = nil
        begin
          response = super(req, body, &block)
        rescue Exception => e # rubocop:disable Lint/RescueException -- recorded, then re-raised untouched
          error = e
          raise
        end
      ensure
        req.delete(HEADER) if added
        if capture
          begin
            req.remove_instance_variable(:@ez_logs_capturing) if req.instance_variable_defined?(:@ez_logs_capturing)
            EzLogsAgent::OutboundCapture.record_http(
              capture[0], capture[1], address, req.method, req.path,
              error ? 0 : (response&.code || capture[3]).to_i, error,
              finished_at: capture[2]
            )
          rescue StandardError
            nil
          end
        end
      end
    end

    # HTTP::Client#perform (the `http` gem, 4.x to 6.x)
    module HttpRb
      def perform(*args, **kwargs, &block)
        req = args.first
        added = false
        capture = nil
        begin
          id = EzLogsAgent::OutgoingHttp.id_for(req.uri.host, req.uri.port, req.headers[HEADER])
          (req.headers[HEADER] = id) && (added = true) if id
          correlation = EzLogsAgent::OutboundCapture.correlation_for(req.uri.host, req.uri.port)
          capture = [correlation, EzLogsAgent::OutboundCapture.clock] if correlation
        rescue StandardError
          capture = nil # never disturb the call
        end
        error = nil
        response = nil
        begin
          response = super
        rescue Exception => e # rubocop:disable Lint/RescueException -- recorded, then re-raised untouched
          error = e
          raise
        end
      ensure
        req.headers.delete(HEADER) if added
        if capture
          begin
            EzLogsAgent::OutboundCapture.record_http(capture[0], capture[1], req.uri.host, req.verb, req.uri.path,
                                                     error ? 0 : response&.code.to_i, error)
          rescue StandardError
            nil
          end
        end
      end
    end

    # Typhoeus::Request#finish: every completed call, alone (#run) or in parallel (Hydra). The time is
    # libcurl's own total_time. Recorded only; the call and its callbacks run as before.
    module TyphoeusRequest
      def finish(response, *rest)
        begin
          uri = URI.parse(base_url.to_s)
          correlation = EzLogsAgent::OutboundCapture.correlation_for(uri.host, uri.port)
          if correlation
            seconds = response.respond_to?(:total_time) ? response.total_time.to_f : 0.0
            started = EzLogsAgent::OutboundCapture.clock - seconds
            method = (options[:method] || :get).to_s
            EzLogsAgent::OutboundCapture.record_http(correlation, started, uri.host, method, uri.path, response.code.to_i)
          end
        rescue StandardError
          nil # never disturb the call
        end
        super
      end
    end

    # An Excon middleware (Excon.defaults[:middlewares]): records each call when it answers or fails.
    class ExconMiddleware
      # Excon's middleware contract (Excon::Middleware::Base): no request keys of its own. Without
      # it Excon warns on every request, and raises for apps that set raise_on_warnings.
      def self.valid_parameter_keys = []

      def initialize(stack)
        @stack = stack
      end

      def request_call(datum)
        begin
          correlation = EzLogsAgent::OutboundCapture.correlation_for(datum[:host], datum[:port])
          datum[:ezlogs_capture] = [correlation, EzLogsAgent::OutboundCapture.clock] if correlation
        rescue StandardError
          nil
        end
        @stack.request_call(datum)
      end

      def response_call(datum)
        record(datum, datum.dig(:response, :status).to_i, nil)
        @stack.response_call(datum)
      end

      def error_call(datum)
        record(datum, 0, datum[:error])
        @stack.error_call(datum)
      end

      private

      def record(datum, status, error)
        capture = datum.delete(:ezlogs_capture)
        return unless capture

        EzLogsAgent::OutboundCapture.record_http(capture[0], capture[1], datum[:host], datum[:method], datum[:path], status, error)
      rescue StandardError
        nil
      end
    end

    def self.install
      Net::HTTP.prepend(NetHttp) unless Net::HTTP.ancestors.include?(NetHttp)
      if defined?(::Typhoeus::Request) && ::Typhoeus::Request.method_defined?(:finish) &&
         !::Typhoeus::Request.ancestors.include?(TyphoeusRequest)
        ::Typhoeus::Request.prepend(TyphoeusRequest)
      end
      if defined?(::Excon) && ::Excon.respond_to?(:defaults) && ::Excon.defaults[:middlewares].is_a?(Array) &&
         !::Excon.defaults[:middlewares].include?(ExconMiddleware)
        ::Excon.defaults[:middlewares] = ::Excon.defaults[:middlewares] + [ExconMiddleware]
      end
      return unless defined?(::HTTP::Client) && ::HTTP::Client.method_defined?(:perform)

      ::HTTP::Client.prepend(HttpRb) unless ::HTTP::Client.ancestors.include?(HttpRb)
    end

    # Host and port, so another app on the same host (localhost:3011 beside the
    # EZLogs server on localhost:3000) still gets the header.
    def self.ezlogs_server?(host, port)
      @ezlogs_server ||= URI.parse(EzLogsAgent.configuration.server_url.to_s).then { |u| [u.host.to_s, u.port] }
      !host.nil? && [host.to_s, port.to_i] == @ezlogs_server
    rescue StandardError
      false
    end

    def self.reset_ezlogs_host!
      @ezlogs_server = nil
    end
  end
end
