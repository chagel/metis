class CreateWorkflowRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :workflow_runs do |t|
      t.references :team, null: false, foreign_key: true
      # A run keeps running if its template is deleted (nullify, not cascade).
      t.references :workflow, null: true, foreign_key: { on_delete: :nullify }
      # One run per conversation — the conversation is the run's substrate.
      t.references :conversation, null: false,
                   foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.integer :status, null: false, default: 0
      t.string :trigger_summary
      t.timestamps
    end
  end
end
