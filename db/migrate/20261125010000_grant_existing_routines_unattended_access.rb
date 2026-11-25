class GrantExistingRoutinesUnattendedAccess < ActiveRecord::Migration[8.1]
  def up
    select_rows(<<~SQL).each do |id, team_id, config|
      SELECT id, team_id, trigger_config FROM routines
      WHERE NOT (trigger_config ? 'grants')
        AND COALESCE(trigger_config->>'purpose', '') <> 'memory_review'
    SQL
      connectors = select_rows("SELECT name, settings FROM connectors WHERE team_id = #{team_id.to_i}")
      names = connectors.map(&:first) + %w[provider:github provider:google provider:x]
      names << "github_bot" if connectors.any? { |_, settings| JSON.parse(settings || "{}")["bot_enabled"].to_s == "true" }
      grants = { "connectors" => names, "actions" => %w[start_workflow] }
      update("UPDATE routines SET trigger_config = #{quote(JSON.parse(config).merge("grants" => grants).to_json)}::jsonb WHERE id = #{id.to_i}")
    end
  end

  def down
    execute("UPDATE routines SET trigger_config = trigger_config - 'grants'")
  end
end
