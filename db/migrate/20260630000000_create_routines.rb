class CreateRoutines < ActiveRecord::Migration[8.1]
  def change
    create_table :routines do |t|
      t.references :team, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :project, foreign_key: true
      t.string :name, null: false
      t.text :prompt, null: false
      t.integer :trigger_source, null: false, default: 0
      t.integer :visibility, null: false, default: 0
      t.boolean :enabled, null: false, default: true
      t.string :cron
      t.string :timezone, null: false, default: "UTC"
      t.string :event_type
      t.jsonb :trigger_config, null: false, default: {}
      t.datetime :next_run_at
      t.datetime :last_run_at

      t.timestamps
    end

    add_index :routines, "team_id, lower((name)::text)", unique: true, name: "index_routines_on_team_id_and_lower_name"
    # The scheduler scans for due rows every minute; the dispatcher matches
    # enabled event routines by type. Index each hot path.
    add_index :routines, [ :enabled, :trigger_source, :next_run_at ], name: "index_routines_on_due"
    add_index :routines, [ :enabled, :trigger_source, :event_type ], name: "index_routines_on_event_dispatch"

    add_reference :conversations, :routine, foreign_key: true
  end
end
