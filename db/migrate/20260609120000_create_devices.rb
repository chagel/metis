class CreateDevices < ActiveRecord::Migration[8.1]
  def change
    create_table :devices do |t|
      t.references :team, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      # SHA256 of the enrollment token; the plaintext is shown once at
      # creation and never stored.
      t.string :token_digest, null: false
      t.string :name, null: false
      # pi | claude-code | codex — which local agent this device drives.
      t.string :agent_kind
      # project/run → local working-dir bindings (Phase 1+).
      t.jsonb :bindings, null: false, default: {}
      # Stamped by the daemon's heartbeat; drives the `online` scope.
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :devices, :token_digest, unique: true
  end
end
