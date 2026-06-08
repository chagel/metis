class CreateTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :tasks do |t|
      t.references :workflow_run, null: false,
                   foreign_key: { on_delete: :cascade }, index: false
      # The assistant turn this step produced — the audit link. Nullify so a
      # purged message doesn't take the task's history with it.
      t.references :assistant_message, null: true,
                   foreign_key: { to_table: :messages, on_delete: :nullify }
      t.references :approved_by, null: true,
                   foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :position, null: false
      t.string :name
      t.text :prompt
      t.integer :gate, null: false, default: 0
      t.integer :status, null: false, default: 0
      t.datetime :decided_at
      t.timestamps
    end
    # Doubles as the workflow_run_id index (left-prefix).
    add_index :tasks, [ :workflow_run_id, :position ], unique: true
  end
end
