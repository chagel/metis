# A delegated task claimed by a machine that died must not park its run
# on awaiting_local forever (docs/local-bridge.md, "Reliability").
# Progress is the heartbeat — claim and events stamp
# tasks.last_reported_at — so a claim silent past
# config.x.bridge.claim_ttl is reclaimed: returned to the unclaimed pool
# for the next pull, invisibly to the user. At
# config.x.bridge.reclaim_cap the task fails and the run surfaces it
# instead of cycling.
#
# Wired in config/recurring.yml (production). Best-effort per row — a
# single failure is logged and the sweep continues. Mirrors
# ReapStalledTurnsJob.
class ReclaimSilentBridgeTasksJob < ApplicationJob
  queue_as :default

  def perform
    cutoff = Time.current - Rails.application.config.x.bridge.claim_ttl
    silent = Task.silent_claims(cutoff).includes(workflow_run: :conversation)

    silent.find_each { |task| sweep(task) }
  end

  private

  def sweep(task)
    label = task.claimed_label
    task.with_lock do
      if task.running? && task.claimed_by_user_id.present?
        if task.reclaims_count >= Rails.application.config.x.bridge.reclaim_cap
          task.workflow_run.fail_silent_task!(task)
        else
          task.reclaim!(label)
          WorkflowBroadcaster.new(task.workflow_run).refresh
        end
      end
    end
  rescue StandardError => e
    Rails.logger.warn(
      "ReclaimSilentBridgeTasksJob: failed for task=#{task.id}: #{e.class}: #{e.message}"
    )
  end
end
