module Agent
  # Renders `history.md` — the operator's recent conversation transcripts,
  # staged into the workspace each turn as a projected input (like
  # `AGENTS.md` and `.mcp.json`). The agent greps/reads it to recall what
  # was discussed, and each section carries the conversation's URL so it
  # can link the operator back. Decryption happens here, in Rails, over
  # the operator's own conversations only. A recent window, not the whole
  # history. See docs/agent-identity.md.
  class History
    FILENAME = "history.md".freeze

    # Bounds, so the file stays small and per-turn decryption is cheap
    # regardless of how long any one conversation got.
    CONVERSATIONS_MAX = 12
    MESSAGES_SCAN_MAX = 60
    TRANSCRIPT_CHARS_MAX = 6000
    MESSAGE_CHARS_MAX = 1500

    def initialize(conversation)
      @conversation = conversation
    end

    def content
      sections = recent_conversations.map { |conversation| conversation_section(conversation) }
      [ header, *sections ].join("\n") + "\n"
    rescue StandardError => e
      # A projected input must never crash a turn (see docs/session-
      # persistence.md). Decrypting recent messages is the realistic
      # failure (a legacy-key row); degrade to the header, keep the turn.
      Rails.logger.warn("Agent::History render failed for conversation #{@conversation.id}: #{e.message}")
      header + "\n"
    end

    private

    def header
      <<~MD.strip
        # Conversation history

        Your recent conversations with this operator, newest first. You start
        every turn fresh — this file is your memory of past chats. grep or read
        it to recall what was discussed. To point the operator at one, link its
        URL, e.g. `[title](/conversations/123)`. A recent window, not the whole
        history.
      MD
    end

    def recent_conversations
      @conversation.user.conversations.active
        .where.not(id: @conversation.id)
        .recent.limit(CONVERSATIONS_MAX).to_a
    end

    def conversation_section(conversation)
      [
        "",
        "## #{conversation.display_title}",
        "- Date: #{conversation.updated_at.to_date.iso8601}",
        "- Link: #{Rails.application.routes.url_helpers.conversation_path(conversation)}",
        "",
        transcript(conversation)
      ].join("\n")
    end

    # User and assistant turns, decrypted, oldest first, stopped once the
    # per-conversation char budget is spent — so a 500-message thread
    # costs the same as a short one.
    def transcript(conversation)
      budget = TRANSCRIPT_CHARS_MAX
      parts = []
      messages = conversation.messages.where(role: %i[user assistant]).chronological.limit(MESSAGES_SCAN_MAX)
      messages.each do |message|
        text = message.content.to_s.strip
        next if text.blank?

        part = "**#{message.user? ? 'Operator' : 'Metis'}:** #{text.truncate(MESSAGE_CHARS_MAX)}"
        parts << part
        budget -= part.length
        break if budget <= 0
      end
      parts.empty? ? "_(no text content)_" : parts.join("\n\n")
    end
  end
end
