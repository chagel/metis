class AddInputToWorkflowRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :workflow_runs, :input, :text
  end
end
