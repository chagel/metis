class AddExternalRefsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :external_refs, :jsonb, default: {}, null: false
  end
end
