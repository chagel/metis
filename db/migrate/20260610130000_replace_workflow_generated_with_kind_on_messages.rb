class ReplaceWorkflowGeneratedWithKindOnMessages < ActiveRecord::Migration[8.1]
  # chat(0) | step_prompt(1) | local_report(2) | review(3) — the boolean
  # couldn't express gate decisions as a third timeline record.
  def up
    add_column :messages, :kind, :integer, null: false, default: 0
    execute "UPDATE messages SET kind = 1 WHERE workflow_generated AND role = 0"
    execute "UPDATE messages SET kind = 2 WHERE workflow_generated AND role = 1"
    remove_column :messages, :workflow_generated
  end

  def down
    add_column :messages, :workflow_generated, :boolean, null: false, default: false
    execute "UPDATE messages SET workflow_generated = TRUE WHERE kind IN (1, 2)"
    remove_column :messages, :kind
  end
end
