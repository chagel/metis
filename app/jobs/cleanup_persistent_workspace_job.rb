# Removes a destroyed conversation's whole persistent scope (sessions
# included). Enqueued from Conversation's after_destroy_commit with bare
# ids — the row is gone by the time this runs.
class CleanupPersistentWorkspaceJob < ApplicationJob
  queue_as :default

  retry_on SystemCallError, wait: :polynomially_longer, attempts: 5

  def perform(user_id:, conversation_id:)
    Agent::Workspace.destroy_scope!(user_id: user_id, conversation_id: conversation_id)
    Rails.logger.info(
      "CleanupPersistentWorkspaceJob: destroyed scope conversation=#{conversation_id} user=#{user_id}"
    )
  end
end
