# frozen_string_literal: true

module EzLogsAgent
  # Records the calls the app makes to outside services (an HTTP request to Stripe, an email sent
  # through Resend) as `outbound_call` steps of the current action. The server decides what they
  # mean (EventIngest::OutboundCalls); this side only measures, without ever slowing or blocking
  # the call:
  #
  # - in the call's path: one clock read before and after, and one push of a small struct into the
  #   bounded buffer. The event, the path pattern and the per-action cap are built later, on the
  #   flush thread (Buffer.flush calls #to_event);
  # - never a body, a query string, a header, a recipient or a subject; the path leaves the process
  #   only as a pattern (deny by default, the server's rule);
  # - never a call outside an action, to the EZLogs server, or to an excluded host;
  # - fails open: nothing here can raise into, hang or retry the app's call.
  module OutboundCapture
    # The server's rules (Summary::OutboundCall, EventIngest::OutboundCalls), so nothing it would drop
    # ever leaves the app: only API versions and the first segment after them when it is a collection
    # ("/v1/customers/cus_9x/orders" → "/v1/customers/:id/:id"); a host's registrable domain, never an
    # address or an internal name.
    WORD = /\A[a-z][a-z_]{0,19}\z/
    PLURAL = /[a-z]s\z/
    NOT_PLURAL = /(?:ss|us|is)\z/
    VERSION = /\Av\d{1,2}\z/
    SECOND_LEVEL = %w[co com net org gov ac edu ne or].freeze
    PRIVATE_SUFFIXES = %w[local internal localhost lan home intranet corp test example invalid].freeze
    HOST = /\A[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?(:\d{1,5})?\z/
    METHODS = %w[GET HEAD POST PUT PATCH DELETE OPTIONS].freeze
    MAX_SEGMENTS = 8
    MAX_PER_ACTION = 50
    READS = %w[GET HEAD].freeze

    # One measured call, waiting in the buffer. Answers the buffer's questions like an event hash.
    Pending = Struct.new(:correlation_id, :at, :duration_ms, :kind, :host, :method, :path, :status, :error_class, :mailer) do
      def [](key)
        case key.to_s
        when "correlation_id" then correlation_id
        when "source_type" then "outbound_call"
        end
      end

      def to_event
        OutboundCapture.build(self)
      end
    end

    @per_action = {}
    @per_action_lock = Mutex.new

    class << self
      def enabled?
        EzLogsAgent.configuration.capture_outbound != false
      rescue StandardError
        false
      end

      # The current action's id when this call should be recorded, else nil. Cheap: no allocation
      # beyond the lookups.
      def correlation_for(host, port)
        return nil unless enabled?

        if (mail = Thread.current[:ez_logs_in_mail_delivery]) # the email's own step covers this call
          mail[:host] ||= host.to_s
          return nil
        end

        id = EzLogsAgent::Correlation.current
        return nil if id.nil? || OutgoingHttp.ezlogs_server?(host, port) || excluded_host?(host)

        id
      rescue StandardError
        nil
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Called once the call returned or raised; never raises.
      # finished_at: when the response headers arrived (a streamed body is read after), else now.
      def record_http(correlation_id, started, host, method, path, status, error = nil, finished_at: nil)
        return unless correlation_id && started

        Buffer.push(Pending.new(correlation_id, Time.now.utc, (((finished_at || clock) - started) * 1000).round, "http",
                                host.to_s, method.to_s.upcase, path.to_s, status.to_i, error&.class&.name, nil))
      rescue StandardError
        nil
      end

      def record_email(correlation_id, started, host, mailer, error = nil)
        return unless correlation_id && started

        Buffer.push(Pending.new(correlation_id, Time.now.utc, ((clock - started) * 1000).round, "email",
                                host.to_s, nil, nil, nil, error&.class&.name, mailer.to_s))
      rescue StandardError
        nil
      end

      # The wire event, built on the flush thread. nil past the per-action cap.
      def build(pending)
        return nil unless count!(pending.correlation_id)

        data = { kind: pending.kind }
        domain = domain_of(pending.host)
        data[:host] = domain unless domain.empty?
        if pending.kind == "email"
          data[:mailer] = pending.mailer unless pending.mailer.to_s.empty?
        else
          data[:method] = pending.method if METHODS.include?(pending.method)
          data[:path] = path_pattern(pending.path)
          data[:status_code] = pending.status
        end
        data[:error_class] = pending.error_class if pending.error_class
        failed = failed?(pending)
        EventBuilder.build(
          source_type: "outbound_call", source_data: data, correlation_id: pending.correlation_id,
          outcome: failed ? "failure" : "success",
          error_message: failed ? (pending.error_class || "HTTP #{pending.status}") : nil,
          duration_ms: [pending.duration_ms.to_i, 0].max, timestamp: pending.at
        )
      rescue StandardError => e
        Logger.error("[OutboundCapture] build failed: #{e.class}")
        nil
      end

      # "/v1/customers/cus_9x/subscriptions?expand=x" → "/v1/customers/:id/subscriptions".
      def path_pattern(path)
        segments = path.to_s.split(/[?#]/, 2).first.to_s.split("/").reject(&:empty?).first(MAX_SEGMENTS)
        first = true
        kept = segments.map do |segment|
          next segment if first && segment.match?(VERSION)

          keep = first && segment.match?(WORD) && segment.match?(PLURAL) && !segment.match?(NOT_PLURAL)
          first = false
          keep ? segment : ":id"
        end
        "/#{kept.join('/')}"
      end

      # Only the registrable domain leaves the app ("api.stripe.com" → "stripe.com"): a subdomain can
      # name a customer ("jsmith.zendesk.com").
      def domain_of(host)
        full = host.to_s.downcase
        return "" unless full.length <= 260 && full.match?(HOST)

        name = full.sub(/:\d+\z/, "")
        return "" if name.match?(/\A[\d.]+\z/)

        labels = name.split(".")
        return "" if labels.size < 2 || PRIVATE_SUFFIXES.include?(labels.last)
        keep = labels.size > 2 && labels[-1].size == 2 && SECOND_LEVEL.include?(labels[-2]) ? 3 : 2
        labels.last(keep).join(".")
      end

      def failed?(pending)
        return !pending.error_class.nil? if pending.kind == "email"

        status = pending.status.to_i
        return true if status.zero?
        return false if status < 400

        !(status == 404 && READS.include?(pending.method.to_s))
      end

      def excluded_host?(host)
        list = EzLogsAgent.configuration.excluded_hosts
        return false if list.nil? || list.empty?

        name = host.to_s.downcase
        list.any? { |h| name == h.to_s.downcase || name.end_with?(".#{h.to_s.downcase}") }
      rescue StandardError
        false
      end

      # At most MAX_PER_ACTION calls per action. Flush thread only; forgets old actions.
      def count!(correlation_id)
        @per_action_lock.synchronize do
          @per_action.clear if @per_action.size > 2_000
          n = (@per_action[correlation_id] || 0) + 1
          @per_action[correlation_id] = n
          n <= MAX_PER_ACTION
        end
      end

      def reset!
        @per_action_lock.synchronize { @per_action = {} }
      end

      # Emails: ActionMailer's "process" names the email (mailer and action), "deliver" sends it.
      # HTTP calls made while delivering (an API-based delivery method) are the email itself: they
      # are not recorded separately, and their host names the email's service.
      def install_mail
        return unless defined?(::ActiveSupport::Notifications)

        ::ActiveSupport::Notifications.subscribe("process.action_mailer") do |*, payload|
          Thread.current[:ez_logs_mail_name] = [payload[:mailer].to_s, payload[:action].to_s] if payload[:mailer] && payload[:action]
        rescue StandardError
          nil
        end
        ::ActiveSupport::Notifications.subscribe("deliver.action_mailer", MailListener.new)
      end
    end

    # start/finish around ActionMailer's delivery.
    class MailListener
      def start(_name, _id, payload)
        return unless OutboundCapture.enabled?

        mail = payload[:mail]
        return if mail.respond_to?(:perform_deliveries) && mail.perform_deliveries == false # nothing is sent
        method = mail.respond_to?(:delivery_method) ? mail.delivery_method : nil
        return if method.nil? || method.class.name.to_s.end_with?("TestMailer", "FileDelivery")

        id = EzLogsAgent::Correlation.current
        return if id.nil?

        Thread.current[:ez_logs_in_mail_delivery] = {
          correlation_id: id, started: OutboundCapture.clock,
          host: (method.settings[:address] if method.respond_to?(:settings) && method.settings.is_a?(Hash)),
          mailer: mail_name(payload[:mailer].to_s)
        }
      rescue StandardError
        nil
      end

      # "FeedbackMailer#received": the action comes from the last email built on this thread, only
      # when it was built by the mailer delivering now (one built and never sent is not this one).
      def mail_name(mailer)
        built = Thread.current[:ez_logs_mail_name]
        built.is_a?(Array) && built.first == mailer ? "#{mailer}##{built.last}" : mailer
      end

      def finish(_name, _id, payload)
        state = Thread.current[:ez_logs_in_mail_delivery]
        Thread.current[:ez_logs_in_mail_delivery] = nil
        Thread.current[:ez_logs_mail_name] = nil
        return unless state

        mailer = state[:mailer].to_s.include?("#") ? state[:mailer] : nil
        OutboundCapture.record_email(state[:correlation_id], state[:started], state[:host], mailer, payload[:exception_object])
      rescue StandardError
        nil
      end
    end
  end
end
