class AddClaimedByUserToTasks < ActiveRecord::Migration[8.1]
  def change
    # Which teammate's machine claimed the delegated task — the bridge
    # token identifies the user at claim time.
    add_reference :tasks, :claimed_by_user, null: true,
                  foreign_key: { to_table: :users, on_delete: :nullify }
  end
end
