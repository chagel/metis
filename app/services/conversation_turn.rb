# The single place a turn is born — shared by the composer (Composing) and
# the workflow engine (WorkflowAdvanceJob).
module ConversationTurn
  # Yields the user message in the txn so the caller can attach uploads.
  # kind renders the user message as a workflow marker instead of a chat
  # bubble (Message#kind) — the engine's step prompts and gate feedback.
  # sender is the acting human; nil when the engine speaks.
  def self.start(conversation, content:, kind: :chat, sender: nil)
    user_message = assistant_message = nil
    conversation.transaction do
      user_message = conversation.messages.create!(
        role: :user, content: content, streaming_status: :done, kind: kind, sender: sender
      )
      yield user_message if block_given?
      # Stamped at send time so duration spans the queue wait too.
      assistant_message = conversation.messages.create!(
        role: :assistant, content: "", streaming_status: :pending, started_at: Time.current
      )
    end
    ChatJob.perform_later(conversation.id, user_message.id, assistant_message.id)
    [ user_message, assistant_message ]
  end
end
