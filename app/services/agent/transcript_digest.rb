module Agent
  # Renders a conversation's prior turns as a quoted plain-text transcript,
  # newest-first within a character budget. Two callers share it: Agent::Identity
  # replays it into AGENTS.md when a sandbox is reaped, and Agent::WorkflowHandoff
  # seeds a spun-off run with the chat that started it.
  class TranscriptDigest
    CHAR_BUDGET = 12_000
    MESSAGE_TRUNCATE = 2_000

    # `agent_label` differs by caller: Identity addresses the same agent
    # ("You"), a handoff describes a different run's agent ("Agent").
    def initialize(conversation, char_budget: CHAR_BUDGET, agent_label: "Agent", operator_label: "Operator")
      @conversation = conversation
      @char_budget = char_budget
      @agent_label = agent_label
      @operator_label = operator_label
    end

    # Walk newest-first so a long reaped conversation only decrypts the
    # messages it keeps; mark how many older ones were dropped.
    def to_s
      rows = @conversation.replayable_history.reverse_order
      kept = []
      total = 0
      truncated = false
      rows.each do |message|
        line = quote(message)
        next unless line
        if kept.any? && total + line.length > @char_budget
          truncated = true
          break
        end

        kept.unshift(line)
        total += line.length
      end

      if truncated
        omitted = rows.size - kept.size
        kept.unshift("_[#{omitted} earlier message#{'s' unless omitted == 1} omitted]_")
      end
      kept.join("\n\n")
    end

    private

    # The `> ` framing reads as quoted transcript and keeps a markdown heading
    # in the content from manufacturing a section the reader treats as its own.
    def quote(message)
      text = message.content.to_s.strip
      return nil if text.blank?

      speaker = message.user? ? @operator_label : @agent_label
      quoted = text.truncate(MESSAGE_TRUNCATE).each_line.map { |line| "> #{line.chomp}" }.join("\n")
      "**#{speaker}:**\n#{quoted}"
    end
  end
end
