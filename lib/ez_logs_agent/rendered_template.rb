# frozen_string_literal: true

require "request_store"

module EzLogsAgent
  # The first view template a request rendered ("app/views/budgets/new.html.erb"),
  # so the HTTP capture can tell a refused save (create rendering "new") from a
  # real one. One ActiveSupport::Notifications subscriber; partials and layouts
  # are separate events and never recorded.
  module RenderedTemplate
    STORE_KEY = :ez_logs_rendered_template
    EVENT = "render_template.action_view"

    def self.install
      return if @installed
      return unless defined?(ActiveSupport::Notifications)

      ActiveSupport::Notifications.subscribe(EVENT) do |*args|
        record(args.last)
      end
      @installed = true
    end

    def self.record(payload)
      identifier = payload.is_a?(Hash) ? payload[:identifier] : nil
      RequestStore.store[STORE_KEY] ||= identifier if identifier
    rescue StandardError
      nil # never disturb rendering
    end

    def self.first
      RequestStore.store[STORE_KEY]
    end

    WROTE_KEY = :ez_logs_wrote_rows

    # Set by the database capturers: this request wrote a row, so a form shown
    # again ("save and add another") is no refused save.
    def self.wrote_rows!
      RequestStore.store[WROTE_KEY] = true
    rescue StandardError
      nil
    end

    def self.wrote_rows?
      RequestStore.store[WROTE_KEY] == true
    end

    # Called at the start of each captured request: never read another request's view.
    def self.reset
      RequestStore.store.delete(STORE_KEY)
      RequestStore.store.delete(WROTE_KEY)
    rescue StandardError
      nil
    end

    def self.installed?
      @installed == true
    end
  end
end
