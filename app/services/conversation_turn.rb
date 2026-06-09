# The single place a turn is born — shared by the composer (Composing) and
# the workflow engine (WorkflowAdvanceJob).
module ConversationTurn
  # Yields the user message in the txn so the caller can attach uploads.
  # workflow_generated marks an engine-injected step prompt, not human input.
  def self.start(conversation, content:, workflow_generated: false)
    user_message = assistant_message = nil
    conversation.transaction do
      user_message = conversation.messages.create!(
        role: :user, content: content, streaming_status: :done,
        workflow_generated: workflow_generated
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
