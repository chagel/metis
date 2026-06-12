# Launching a run now requires a project (daemons claim delegated steps per
# project), so runs born without one predate the rule and can never finish —
# close them out instead of carrying a legacy state.
class CancelProjectlessWorkflowRuns < ActiveRecord::Migration[8.1]
  PROJECTLESS_ACTIVE = <<~SQL.freeze
    SELECT workflow_runs.id FROM workflow_runs
    JOIN conversations ON conversations.id = workflow_runs.conversation_id
    WHERE conversations.project_id IS NULL
      AND workflow_runs.status IN (0, 1, 2, 6)
  SQL

  def up
    # Unsettled tasks first: pending -> skipped, in-flight -> rejected
    # (mirrors reject_current_gate!), so nothing stays claimable.
    execute <<~SQL
      UPDATE tasks SET status = CASE WHEN status = 0 THEN 6 ELSE 4 END
      WHERE status IN (0, 1, 2) AND workflow_run_id IN (#{PROJECTLESS_ACTIVE})
    SQL
    execute <<~SQL
      UPDATE workflow_runs SET status = 5 WHERE id IN (#{PROJECTLESS_ACTIVE})
    SQL
  end

  def down; end
end
