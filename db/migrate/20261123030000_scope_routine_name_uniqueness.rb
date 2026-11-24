class ScopeRoutineNameUniqueness < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :routines, "team_id, lower((name)::text)", unique: true, where: "visibility = 1",
      name: "index_routines_on_team_lower_name_team_scope", algorithm: :concurrently
    add_index :routines, "team_id, user_id, lower((name)::text)", unique: true, where: "visibility = 0",
      name: "index_routines_on_team_user_lower_name_personal", algorithm: :concurrently
    remove_index :routines, name: "index_routines_on_team_id_and_lower_name", algorithm: :concurrently
  end

  def down
    add_index :routines, "team_id, lower((name)::text)", unique: true,
      name: "index_routines_on_team_id_and_lower_name", algorithm: :concurrently
    remove_index :routines, name: "index_routines_on_team_user_lower_name_personal", algorithm: :concurrently
    remove_index :routines, name: "index_routines_on_team_lower_name_team_scope", algorithm: :concurrently
  end
end
