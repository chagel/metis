class AddWorkflowGeneratedToMessages < ActiveRecord::Migration[8.1]
  def change
    # A user message the engine injected as a step prompt (not human-typed);
    # the chat renders it as a step instruction, not a user bubble.
    add_column :messages, :workflow_generated, :boolean, default: false, null: false
  end
end
