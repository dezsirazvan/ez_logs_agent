# frozen_string_literal: true

require "set" # Ruby 3.1 doesn't autoload it

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
    # ever leaves the app: the path kept by REST structure (#keep_segment?: "/v1/customers/cus_9x/orders"
    # → "/v1/customers/:id/orders"); a host's registrable domain, never an address or an internal name.
    # A collection word is kept only when it is one of these common API collections
    # ("/v1/charges" → "Created a charge"). Any other word becomes :id, even one that looks plural:
    # "charles" or "james" could be a person (owner decision, 2026-11-21). Identical in the server,
    # ez_logs_agent and ezlogs-nextjs (spec/domain/summary/outbound_call_spec.rb checks).
    COLLECTIONS = %w[
      accounts activities addresses agents alerts apps assets assistants attachments audiences
      balances batches bookings calendars calls campaigns cards carts categories channels charges
      chats checkouts comments companies completions contacts conversations coupons credits
      customers deals deployments devices discounts disputes documents domains emails embeddings
      events files forms groups images invoices issues items jobs leads links lists locations logs
      meetings members messages metrics models notes notifications orders organizations pages
      payment_intents payment_methods payments payouts people plans posts prices products profiles projects prompts queries records
      refunds reports requests responses reviews rooms runs sessions shipments sites sources spaces
      subscribers subscriptions tasks teams templates threads tickets tokens transactions
      transcriptions transfers translations uploads users videos webhooks workspaces
    ].to_set.freeze
    # Generic API vocabulary, kept by REST structure (deny by default): a verb only as the last segment,
    # where the operation sits ("/charges/:id/refund", "/link/token/create"); a noun, like a collection,
    # only where a collection sits: first (after the version), after an id, or after a kept noun
    # ("/link/token/create", "/v1/checkout/sessions"). Right after a collection comes an id's place,
    # where a name could be ("/users/chat" → "/users/:id"). No vendor's words. Identical in the three places.
    API_VERBS = %w[
      approve archive authorize cancel capture complete confirm create delete download exchange export
      finalize get import invalidate list lookup pay refresh refund reject remove resend
      restore retrieve reverse search send start stop sync update upload validate verify
      void
    ].freeze
    API_NOUNS = %w[auth balance chat checkout item link token].freeze
    # An API prefix: "api" or a version ("v1", "v2"), kept wherever it sits ("/api/v2/models"):
    # never a name. A date version ("2010-04-01") stays an id.
    API_PREFIX = /\A(?:api|v\d{1,2})\z/
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
        # scrub: invalid UTF-8 would raise in split and lose the call; "?" ends the path there, so it never forms a word.
        all = path.to_s.scrub("?").split(/[?#]/, 2).first.to_s.split("/").reject(&:empty?)
        kept = []
        all.first(MAX_SEGMENTS).each_with_index do |segment, i|
          kept << (keep_segment?(segment, i, all.size, kept) ? segment : ":id")
        end
        "/#{kept.join('/')}"
      end

      # An API prefix ("api", a version) anywhere; a collection or API noun where a collection sits (first, after an id that
      # follows a kept collection or noun, after a kept noun); an API verb only as the very last segment and only
      # after such an id or a kept noun ("/charges/:id/refund", "/link/token/create"), never right after
      # a collection or a masked segment, where a name could be ("/users/pay", "/acme/chat").
      def keep_segment?(segment, index, total, kept)
        return true if segment.match?(API_PREFIX)

        previous = kept.last
        id_slot = previous == ":id" && kept.size >= 2 && kept[-2] != ":id" && !kept[-2].match?(API_PREFIX)
        after_noun = API_NOUNS.include?(previous)
        return index == total - 1 && (id_slot || after_noun) if API_VERBS.include?(segment)
        return false unless COLLECTIONS.include?(segment) || API_NOUNS.include?(segment)

        previous.nil? || previous.match?(API_PREFIX) || id_slot || after_noun
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
