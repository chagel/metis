# Returns claims silent past config.x.bridge.claim_ttl to the unclaimed
# pool; at config.x.bridge.reclaim_cap the task fails and the run
# surfaces it instead of cycling (docs/local-bridge.md, "Reliability").
# Wired in config/recurring.yml. Mirrors ReapStalledTurnsJob.
class ReclaimSilentBridgeTasksJob < ApplicationJob
  queue_as :default

  def perform
    cutoff = Time.current - Rails.application.config.x.bridge.claim_ttl
    silent = Task.silent_claims(cutoff).includes(workflow_run: :conversation)

    silent.find_each { |task| sweep(task) }
  end

  private

  # Best-effort per row — a single failure is logged and the sweep continues.
  def sweep(task)
    reclaimed = false
    task.with_lock do
      if task.running? && task.claimed?
        if task.reclaims_count >= Rails.application.config.x.bridge.reclaim_cap
          task.workflow_run.fail_silent_task!(task)
        else
          task.reclaim!
          reclaimed = true
        end
      end
    end
    WorkflowBroadcaster.new(task.workflow_run).refresh if reclaimed
  rescue StandardError => e
    Rails.logger.warn(
      "ReclaimSilentBridgeTasksJob: failed for task=#{task.id}: #{e.class}: #{e.message}"
    )
  end
end
