class RemoveExternalRefsFromProjects < ActiveRecord::Migration[8.1]
  def change
    remove_column :projects, :external_refs, :jsonb, default: {}, null: false
  end
end
