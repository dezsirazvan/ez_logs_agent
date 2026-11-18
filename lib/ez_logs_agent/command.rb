# frozen_string_literal: true

require "request_store"

module EzLogsAgent
  # Work someone runs by hand or on a schedule, outside any request or job: a Rails console line,
  # a rake task, a `rails runner` script. Without this its database writes ship with no
  # correlation id, so they never form an action and never show; a change made in the console
  # was invisible. Each run now gets its own correlation id, and its database events name who ran
  # it ("Rails console (razvan)", "rake orders:backfill"), so it reads as one action.
  #
  # Never nests: inside a request, a job or another command it does nothing, so the work joins the
  # surrounding action as before. Never raises into the host: a failure here only means the run is
  # captured as it was before (uncorrelated).
  module Command
    ACTOR_KEY = :ez_logs_command_actor
    CORRELATION_KEY = :ez_logs_command_correlation
    STARTED_KEY = :ez_logs_command_started
    JOB_DEPTH_KEY = :ez_logs_command_job_depth
    CONSOLE_KEY = :ez_logs_command_from_console
    # A command running longer (a loop, a long backfill) continues as a new action under the same
    # name, so one never grows without bound. shortcut: fixed, make it configurable if asked.
    MAX_ACTION_SECONDS = 600

    class << self
      # Runs the block as one command. A no-op wrapper when a correlation is already active.
      def run(actor_id:, label:)
        started = start(actor_id: actor_id, label: label)
        yield
      ensure
        finish if started
      end

      # Starts a command with no end (a `rails runner` script: the rest of the process).
      # @return [Boolean] whether a command was started
      def start(actor_id:, label:)
        return false unless EzLogsAgent.configuration.capture_commands
        return false if EzLogsAgent::Correlation.current

        id = EzLogsAgent::Correlation.generate
        EzLogsAgent::Correlation.current = id
        RequestStore.store[CORRELATION_KEY] = id
        RequestStore.store[STARTED_KEY] = now
        RequestStore.store[ACTOR_KEY] = { id: actor_id.to_s[0, 200], label: label.to_s[0, 200], kind: "system" }
        true
      rescue StandardError => e
        EzLogsAgent::Logger.debug("[Command] start failed: #{e.message}")
        false
      end

      def finish
        RequestStore.store.delete(ACTOR_KEY)
        RequestStore.store.delete(CORRELATION_KEY)
        RequestStore.store.delete(STARTED_KEY)
        EzLogsAgent::Correlation.clear
      rescue StandardError => e
        EzLogsAgent::Logger.debug("[Command] finish failed: #{e.message}")
      end

      # The correlation id a database event takes now: the current one, except that a command past
      # MAX_ACTION_SECONDS moves on to a new one. Inside a job the command started, the job's own
      # correlation is left alone.
      def correlation
        current = EzLogsAgent::Correlation.current
        store = RequestStore.store
        return current unless current && store[CORRELATION_KEY] == current
        return current if store[JOB_DEPTH_KEY].to_i.positive? # a job's writes stay with the job
        return current if now - store[STARTED_KEY].to_f < MAX_ACTION_SECONDS

        fresh = EzLogsAgent::Correlation.generate
        EzLogsAgent::Correlation.current = fresh
        store[CORRELATION_KEY] = fresh
        store[STARTED_KEY] = now
        fresh
      rescue StandardError
        EzLogsAgent::Correlation.current
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Whether `correlation_id` is a running command's own id. A job enqueued under it does not
      # carry it: a backfill enqueuing thousands of jobs would fold them all into one action.
      def owns?(correlation_id)
        !correlation_id.nil? && RequestStore.store[CORRELATION_KEY] == correlation_id
      rescue StandardError
        false
      end

      # Marks a job running in this thread (ActiveJob / Sidekiq capturers), so a long command never
      # moves on to a new action in the middle of a job that took the command's id.
      def in_job
        store = RequestStore.store
        store[JOB_DEPTH_KEY] = store[JOB_DEPTH_KEY].to_i + 1
        yield
      ensure
        RequestStore.store[JOB_DEPTH_KEY] = [RequestStore.store[JOB_DEPTH_KEY].to_i - 1, 0].max
      end

      # The running command's actor, or nil outside a command.
      def actor
        RequestStore.store[ACTOR_KEY]
      rescue StandardError
        nil
      end

      # A database event's context with the running command's actor added (unchanged outside one).
      def with_actor(context)
        actor = self.actor
        return context unless actor

        (context || {}).merge(actor: actor)
      end

      # "Rails console (razvan)": the OS account that opened it, when the environment names one.
      def console_actor
        user = ENV["USER"].to_s.scrub.strip
        user = ENV["LOGNAME"].to_s.scrub.strip if user.empty?
        user = user.gsub(/[^[:print:]]/, "")[0, 64]
        user.empty? ? { actor_id: "console", label: "Rails console" } : { actor_id: "console:#{user}", label: "Rails console (#{user})" }
      rescue StandardError
        { actor_id: "console", label: "Rails console" }
      end

      # Hooks the console so each line typed is one command: IRB (Rails' default), or Pry
      # (pry-rails) through its eval hooks.
      def install_console
        if defined?(::PryRails) && defined?(::Pry) && ::Pry.respond_to?(:hooks)
          # Each line ends only a command a console line started (never a rake task's that reached a
          # binding.pry); before_eval ends the previous line's first, in case it raised past after_eval.
          # shortcut: a binding.pry nested inside a console line ends that line's command early; the
          # rest of the line is captured uncorrelated, as before 0.2.6.
          ::Pry.hooks.add_hook(:before_eval, :ez_logs_command) { |*| finish_console_line; start_console_line }
          ::Pry.hooks.add_hook(:after_eval, :ez_logs_command) { |*| finish_console_line }
        else
          require "irb"
          ::IRB::Context.prepend(IrbLine) unless ::IRB::Context < IrbLine
        end
      rescue StandardError, LoadError => e
        EzLogsAgent::Logger.debug("[Command] console hook not installed: #{e.message}")
      end

      def start_console_line
        RequestStore.store[CONSOLE_KEY] = true if start(**console_actor)
      rescue StandardError
        nil
      end

      def finish_console_line
        return unless RequestStore.store.delete(CONSOLE_KEY)

        finish
      rescue StandardError
        nil
      end

      def rake_task_excluded?(name)
        EzLogsAgent.configuration.all_excluded_rake_tasks.any? do |pattern|
          pattern.end_with?("*") ? name.to_s.start_with?(pattern.chomp("*")) : name.to_s == pattern
        end
      rescue StandardError
        true # unsure: leave the task as it was
      end

      def install_rake
        ::Rake::Task.prepend(RakeTask) if defined?(::Rake::Task) && !(::Rake::Task < RakeTask)
      rescue StandardError => e
        EzLogsAgent::Logger.debug("[Command] rake hook not installed: #{e.message}")
      end
    end

    # One IRB line = one command.
    module IrbLine
      def evaluate(*args, **kwargs, &block)
        EzLogsAgent::Command.run(**EzLogsAgent::Command.console_actor) { super }
      end
    end

    # One rake task = one command; a task it invokes joins it. A task that runs a job worker
    # (config.excluded_rake_tasks) is left alone.
    module RakeTask
      def execute(*args, **kwargs, &block)
        return super if EzLogsAgent::Command.rake_task_excluded?(name)

        EzLogsAgent::Command.run(actor_id: "rake:#{name}", label: "rake #{name}") { super }
      end
    end
  end
end
