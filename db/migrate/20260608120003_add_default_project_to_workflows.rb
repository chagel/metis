class AddDefaultProjectToWorkflows < ActiveRecord::Migration[8.1]
  def change
    # A suggested context at launch, overridable. Nullify so deleting a
    # project doesn't take its workflows with it.
    add_reference :workflows, :default_project, null: true,
                  foreign_key: { to_table: :projects, on_delete: :nullify }
  end
end
