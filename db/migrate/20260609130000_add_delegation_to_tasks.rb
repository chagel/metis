class AddDelegationToTasks < ActiveRecord::Migration[8.1]
  def change
    # A delegated step runs on a user's enrolled machine (docs/local-bridge.md)
    # instead of as a cloud ChatJob turn.
    add_column :tasks, :delegated, :boolean, null: false, default: false
    # The device that claimed this delegated task off the pull API.
    add_reference :tasks, :claimed_by_device, null: true,
                  foreign_key: { to_table: :devices, on_delete: :nullify }
    # The local agent's reported outcome: { status, summary, artifacts }.
    add_column :tasks, :result, :jsonb, null: false, default: {}
    # Optional progress log lines posted while the local agent works.
    add_column :tasks, :progress, :jsonb, null: false, default: []
    # When the engine handed the task off — drives claim ordering (FIFO).
    add_column :tasks, :dispatched_at, :datetime
  end
end
