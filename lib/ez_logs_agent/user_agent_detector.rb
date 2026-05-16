# frozen_string_literal: true

module EzLogsAgent
  # Detects whether an HTTP request originated from an AI agent client
  # (Claude Desktop, ChatGPT, Cursor, Windsurf, …) by inspecting the
  # User-Agent string.
  #
  # Behavior is intentionally narrow: returns vendor metadata only when
  # the UA starts with one of the known LLM-client prefixes. Anything
  # else returns nil — we never *infer* agency from weak signals.
  #
  # The Next.js agent ships an identical detector
  # (`src/user-agent-detector.ts`) so both wire-format emitters classify
  # the same UA the same way.
  module UserAgentDetector
    # Patterns are matched case-insensitively against the start of the
    # User-Agent string. New vendors must be added in BOTH agents.
    PATTERNS = [
      { prefix: "claude-",     vendor: "claude",     label: "Claude" },
      { prefix: "anthropic-",  vendor: "claude",     label: "Claude" },
      { prefix: "gpt-",        vendor: "openai",     label: "ChatGPT" },
      { prefix: "chatgpt-",    vendor: "openai",     label: "ChatGPT" },
      { prefix: "openai-",     vendor: "openai",     label: "ChatGPT" },
      { prefix: "cursor-",     vendor: "cursor",     label: "Cursor" },
      { prefix: "windsurf-",   vendor: "windsurf",   label: "Windsurf" }
    ].freeze

    # Classify a User-Agent string.
    #
    # @param user_agent [String, nil] Raw User-Agent header value.
    # @return [Hash, nil] `{ kind: "agent", vendor:, label:, suggested_id: }`
    #   when the UA matches a known LLM client; nil otherwise.
    def self.classify(user_agent)
      return nil if user_agent.nil? || user_agent.empty?

      ua = user_agent.downcase
      match = PATTERNS.find { |p| ua.start_with?(p[:prefix]) }
      return nil unless match

      {
        kind: "agent",
        vendor: match[:vendor],
        label: match[:label],
        suggested_id: "agent:#{match[:vendor]}"
      }
    rescue
      # Defensive: classifier must never crash the middleware.
      nil
    end
  end
end
