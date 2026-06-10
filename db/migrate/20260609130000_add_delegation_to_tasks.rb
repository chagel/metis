class AddDelegationToTasks < ActiveRecord::Migration[8.1]
  def change
    # A delegated step runs on the user's own machine (docs/local-bridge.md)
    # instead of as a cloud ChatJob turn.
    add_column :tasks, :delegated, :boolean, null: false, default: false
    # Client-reported name of the machine that claimed the task ("mikes-mbp")
    # — display/audit only, no registry behind it.
    add_column :tasks, :claimed_by, :string
    # The local agent's reported outcome: { status, summary, artifacts }.
    add_column :tasks, :result, :jsonb, null: false, default: {}
    # Optional progress log lines posted while the local agent works.
    add_column :tasks, :progress, :jsonb, null: false, default: []
    # When the engine handed the task off — drives claim ordering (FIFO).
    add_column :tasks, :dispatched_at, :datetime
  end
end
