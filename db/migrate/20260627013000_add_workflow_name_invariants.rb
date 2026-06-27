class AddWorkflowNameInvariants < ActiveRecord::Migration[8.1]
  def change
    add_index :workflows, "team_id, lower(name)",
      unique: true,
      name: "index_workflows_on_team_id_and_lower_name"
  end
end
