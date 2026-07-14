class CleanupPersistentWorkspaceJob < ApplicationJob
  queue_as :default

  discard_on Agent::WorkspaceCleanup::UnsafePath, ArgumentError do |job, error|
    job.log_failure(error)
  end

  retry_on SystemCallError, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.log_failure(error)
  end

  def perform(user_id:, conversation_id:)
    Agent::WorkspaceCleanup.new(user_id: user_id, conversation_id: conversation_id).destroy_scope!
    Rails.logger.info(
      "event=persistent_workspace_destroyed conversation_id=#{conversation_id} user_id=#{user_id}"
    )
  end

  def log_failure(error)
    ids = arguments.first.symbolize_keys
    Rails.logger.error(
      "event=persistent_workspace_destroy_failed conversation_id=#{ids[:conversation_id]} " \
      "user_id=#{ids[:user_id]} error_class=#{error.class} error=#{error.message.inspect}"
    )
  end
end
