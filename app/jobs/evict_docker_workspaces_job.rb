# Reclaims idle Docker-runtime workspaces so the persistent root behaves
# like a hot cache, not permanent storage (docs/session-persistence.md).
# Two passes per run: retention (warm-evict scopes past their policy
# window) and, when the filesystem is below the low watermark, emergency
# eviction of otherwise-eligible scopes oldest-first until the recovery
# watermark. Warm eviction deletes workspace/ only — sessions/ stays, so
# pi still resumes with --continue and no DB history replay.
#
# Every eviction re-checks eligibility under the conversation row lock —
# the same lock ConversationTurn.start takes — so deletion can never race
# a turn being born. Best-effort per record, like EvictPausedSandboxesJob:
# one bad scope is logged and the batch continues.
class EvictDockerWorkspacesJob < ApplicationJob
  queue_as :default

  def perform
    @stats = Hash.new(0)
    free_before = Agent::WorkspaceCleanup.free_space
    evict_due_candidates
    emergency = emergency_evict
    free_after = Agent::WorkspaceCleanup.free_space
    log_summary(free_before, free_after, emergency)
  end

  private

  def config = Rails.application.config.x.agent

  def evict_due_candidates
    due_scope.find_each do |conversation|
      @stats[:scanned] += 1
      evict(conversation) { |fresh| retention_reason(fresh) }
    end
  end

  # Coarse SQL bound — Docker runtime, marker clear, quiet past the
  # shortest window. Precise classification happens per row, re-checked
  # under the lock.
  def due_scope
    shortest = [ config.docker_workflow_eviction_window,
                 config.docker_workspace_eviction_window,
                 config.docker_archived_workspace_eviction_window ].min
    Conversation.docker_workspace_present.docker_workspace_idle_before(shortest.ago)
  end

  # The eviction reason the retention policy assigns right now, or nil
  # when the scope must stay. Workflow classification wins over archived
  # and ordinary; active workflows never evict.
  def retention_reason(conversation, now = Time.current)
    run = conversation.workflow_run
    if run
      return nil if run.active?

      base = [ run.updated_at, conversation.docker_workspace_last_used_at, conversation.updated_at ].compact.max
      "workflow_terminal" if base <= now - config.docker_workflow_eviction_window
    elsif conversation.archived?
      base = [ conversation.archived_at, conversation.docker_workspace_last_used_at, conversation.updated_at ].compact.max
      "archived_idle" if base <= now - config.docker_archived_workspace_eviction_window
    else
      base = [ conversation.docker_workspace_last_used_at, conversation.updated_at ].compact.max
      "ordinary_idle" if base <= now - config.docker_workspace_eviction_window
    end
  end

  # Warm-evict one conversation's workspace under its row lock. The block
  # receives the freshly locked row and returns the eviction reason, or
  # nil to leave it alone.
  def evict(conversation)
    conversation.with_lock do
      if (skip = skip_reason(conversation))
        @stats[:skipped_active] += 1 if %w[turn_inflight workflow_active].include?(skip)
        Rails.logger.info("event=docker_workspace_eviction_skipped conversation_id=#{conversation.id} reason=#{skip}")
        next
      end

      reason = yield(conversation)
      next unless reason

      bytes = Agent::WorkspaceCleanup.for(conversation).evict_workspace!
      conversation.update_columns(
        docker_workspace_evicted_at: Time.current,
        docker_workspace_eviction_reason: reason
      )
      Rails.logger.info(
        "event=docker_workspace_evicted conversation_id=#{conversation.id} " \
        "user_id=#{conversation.user_id} reason=#{reason} bytes_reclaimed=#{bytes}"
      )
      @stats[:reclaimed] += 1
      @stats[:bytes_reclaimed] += bytes
    end
  rescue StandardError => e
    @stats[:failures] += 1
    Rails.logger.error(
      "event=docker_workspace_eviction_failed conversation_id=#{conversation.id} " \
      "error_class=#{e.class} error=#{e.message.inspect}"
    )
  end

  # Under-lock activity re-checks. with_lock reloaded the row, so these
  # read current state, not what the candidate scan saw.
  def skip_reason(conversation)
    return "already_evicted" if conversation.docker_workspace_evicted?
    return "runtime_mismatch" unless conversation.runtime_label == "docker"
    return "turn_inflight" if conversation.turn_in_progress?
    return "workflow_active" if conversation.workflow_run&.active?

    nil
  end

  # Below the low watermark, evict otherwise-eligible Docker scopes
  # oldest-first — retention deadlines waived, activity checks not — until
  # the recovery watermark or exhaustion. A nil free-space probe performs
  # no deletion at all: unknown must never read as "disk full".
  def emergency_evict
    space = Agent::WorkspaceCleanup.free_space
    return false if space.nil? || space.free_percent >= config.persistent_low_watermark_percent

    recovered = false
    emergency_candidate_ids.each do |id|
      conversation = Conversation.find_by(id: id)
      next unless conversation

      @stats[:scanned] += 1
      evict(conversation) { "low_disk" }

      space = Agent::WorkspaceCleanup.free_space
      break if space.nil?
      if space.free_percent >= config.persistent_recovery_watermark_percent
        recovered = true
        break
      end
    end
    unless recovered
      Rails.logger.warn("event=docker_workspace_eviction_low_disk_unrecovered free_percent=#{space&.free_percent&.round(1)}")
    end
    true
  end

  def emergency_candidate_ids
    Conversation.docker_workspace_present.docker_workspace_oldest_first.pluck(:id)
  end

  def log_summary(free_before, free_after, emergency)
    total_bytes = Agent::WorkspaceCleanup.bytes_under(Agent::Workspace::PERSISTENT_ROOT)
    Rails.logger.info(
      "event=docker_workspace_eviction_summary scopes_scanned=#{@stats[:scanned]} " \
      "total_bytes=#{total_bytes} scopes_reclaimed=#{@stats[:reclaimed]} " \
      "bytes_reclaimed=#{@stats[:bytes_reclaimed]} failures=#{@stats[:failures]} " \
      "skipped_active=#{@stats[:skipped_active]} " \
      "free_percent_before=#{free_before&.free_percent&.round(1)} " \
      "free_percent_after=#{free_after&.free_percent&.round(1)} emergency=#{emergency}"
    )
  end
end
