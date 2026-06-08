class CreateWorkflows < ActiveRecord::Migration[8.1]
  def change
    create_table :workflows do |t|
      t.references :team, null: false, foreign_key: true
      t.string :name, null: false
      t.string :description
      # Ordered step definitions: [{ "key", "name", "prompt", "gate" }, ...]
      t.jsonb :steps, null: false, default: []
      t.integer :trigger_source, null: false, default: 0
      t.jsonb :trigger_config, null: false, default: {}
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
  end
end
