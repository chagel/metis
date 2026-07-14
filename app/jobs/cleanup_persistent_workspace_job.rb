# Removes a destroyed conversation's whole persistent scope — sessions
# included — after the destroy transaction commits (Conversation
# after_destroy_commit). Best-effort and idempotent: the scope may already
# be gone, and a duplicate enqueue is harmless. A malformed or unsafe path
# is logged and never retried.
class CleanupPersistentWorkspaceJob < ApplicationJob
  queue_as :default

  def perform(user_id:, conversation_id:)
    Agent::WorkspaceCleanup.new(user_id: user_id, conversation_id: conversation_id).destroy_scope!
    Rails.logger.info(
      "event=persistent_workspace_destroyed conversation_id=#{conversation_id} user_id=#{user_id}"
    )
  rescue StandardError => e
    Rails.logger.error(
      "event=persistent_workspace_destroy_failed conversation_id=#{conversation_id} " \
      "user_id=#{user_id} error_class=#{e.class} error=#{e.message.inspect}"
    )
  end
end
