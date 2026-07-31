# Warm-evicts idle host-backed workspaces — the runtimes that bind-mount
# a persistent host directory (docker, microsandbox) — so that root
# behaves like a hot cache, not permanent storage
# (docs/session-persistence.md): workspace/ is deleted, sessions/ stays,
# so pi still resumes with --continue and no DB history replay. No
# marker is written — both runtimes detect the missing workspace at the
# next turn and warn the agent.
#
# Eligibility is re-checked under the conversation row lock — the same
# lock ConversationTurn.start takes — so an eviction can never race a
# turn being born. Best-effort per row, like EvictPausedSandboxesJob:
# one bad scope is logged and the loop continues.
class EvictDockerWorkspacesJob < ApplicationJob
  queue_as :default

  def perform
    cutoff = Time.current - Rails.application.config.x.agent.docker_workspace_eviction_window
    Conversation.host_workspace_evictable(cutoff).select(:id, :user_id).find_each do |conversation|
      evict(conversation, cutoff)
    end
  end

  private

  def evict(conversation, cutoff)
    workspace = Agent::Workspace.persistent(conversation)
    return unless workspace.workspace_dir.directory?

    conversation.with_lock do
      next unless evictable?(conversation, cutoff)

      workspace.evict_workspace!
      Rails.logger.info("EvictDockerWorkspacesJob: evicted conversation=#{conversation.id}")
    end
  rescue StandardError => e
    Rails.logger.warn(
      "EvictDockerWorkspacesJob: failed for conversation=#{conversation.id} #{e.class}: #{e.message}"
    )
  end

  # with_lock reloaded the row, so these read current state, not what
  # the candidate scan saw.
  def evictable?(conversation, cutoff)
    conversation.updated_at <= cutoff &&
      !conversation.turn_in_progress? &&
      !conversation.workflow_run&.active?
  end
end
