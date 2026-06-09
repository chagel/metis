class AddWorkflowGeneratedToMessages < ActiveRecord::Migration[8.1]
  def change
    # Marks a user message the workflow engine injected as a step prompt
    # (not something the human typed) so the chat renders it as a step
    # instruction rather than a user bubble.
    add_column :messages, :workflow_generated, :boolean, default: false, null: false
  end
end
