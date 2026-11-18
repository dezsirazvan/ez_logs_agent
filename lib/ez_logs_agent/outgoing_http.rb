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
      id = EzLogsAgent::Correlation.current
      id if id && existing.nil? && !ezlogs_server?(host, port)
    rescue StandardError
      nil
    end

    # Net::HTTP#request
    # The header is removed again after the call: an app that reuses its request
    # object must never send this action's id with a later one.
    module NetHttp
      def request(req, body = nil, &block)
        added = false
        begin
          id = EzLogsAgent::OutgoingHttp.id_for(address, port, req[HEADER])
          (req[HEADER] = id) && (added = true) if id
        rescue StandardError
          nil # never disturb the call
        end
        super
      ensure
        req.delete(HEADER) if added
      end
    end

    # HTTP::Client#perform (the `http` gem, 4.x to 6.x)
    module HttpRb
      def perform(*args, **kwargs, &block)
        req = args.first
        added = false
        begin
          id = EzLogsAgent::OutgoingHttp.id_for(req.uri.host, req.uri.port, req.headers[HEADER])
          (req.headers[HEADER] = id) && (added = true) if id
        rescue StandardError
          nil # never disturb the call
        end
        super
      ensure
        req.headers.delete(HEADER) if added
      end
    end

    def self.install
      Net::HTTP.prepend(NetHttp) unless Net::HTTP.ancestors.include?(NetHttp)
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
