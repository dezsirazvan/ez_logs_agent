# frozen_string_literal: true

module EzLogsAgent
  # A row change is sent only once its transaction commits, so a rolled-back write (a failed step
  # later in the transaction, ActiveRecord::Rollback, a rolled-back savepoint) never reads as done.
  # Kept on the transaction itself (Rails 7.2+: ActiveRecord::Transaction#after_commit, which runs
  # after the outermost commit and never after a rollback), never on the record: two objects for one
  # row, or a record reused across savepoints, lose nothing. No callback is added to any model.
  # Older Rails has no such hook: changes are sent at once, as before.
  module Transactional
    # Past this many waiting changes in one transaction (an import), the rest go out at once: memory
    # stays bounded, and a rollback of such a run is rare.
    MAX_WAITING = 10_000
    COUNTS = ObjectSpace::WeakMap.new

    module_function

    # For a model's own connection, without leasing one permanently (apps that set
    # ActiveRecord.permanent_connection_checkout = :disallowed refuse Model.connection).
    def push_for(klass, event)
      if klass.respond_to?(:with_connection)
        klass.with_connection { |connection| push(connection, event) }
      else
        push(klass.connection, event)
      end
    rescue StandardError
      EzLogsAgent::Buffer.push(event)
    end

    def push(connection, event)
      return unless event

      transaction = connection.respond_to?(:current_transaction) ? connection.current_transaction : nil
      user = transaction.respond_to?(:user_transaction) && transaction.open? ? transaction.user_transaction : nil
      unless user.respond_to?(:after_commit) && waiting!(user)
        EzLogsAgent::Buffer.push(event)
        return
      end

      user.after_commit { EzLogsAgent::Transactional.release(event) }
    rescue StandardError
      EzLogsAgent::Buffer.push(event)
    end

    # Runs inside the app's commit: never raises into it.
    def release(event)
      EzLogsAgent::Buffer.push(event)
    rescue StandardError => e
      EzLogsAgent::Logger.error("[Transactional] release failed: #{e.class} - #{e.message}")
    end

    # Counts a change waiting on this transaction; false once it holds MAX_WAITING.
    def waiting!(transaction)
      count = COUNTS[transaction].to_i
      return false if count >= MAX_WAITING

      COUNTS[transaction] = count + 1
      true
    end
  end
end
