# Fired runs now carry their routine's purpose in settings, so a purpose run
# stays identifiable after its routine is deleted. Tag the runs fired before.
class TagPurposeRoutineRuns < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE conversations SET settings = conversations.settings || jsonb_build_object('purpose', routines.trigger_config->>'purpose')
      FROM routines
      WHERE conversations.routine_id = routines.id AND routines.trigger_config ? 'purpose'
    SQL
  end

  def down; end
end
