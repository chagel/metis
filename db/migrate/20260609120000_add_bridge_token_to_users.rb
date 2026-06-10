class AddBridgeTokenToUsers < ActiveRecord::Migration[8.1]
  def change
    # SHA256 of the user's bridge token (docs/local-bridge.md) — the PAT a
    # local agent uses to pull delegated tasks. Plaintext shown once.
    add_column :users, :bridge_token_digest, :string
    add_index :users, :bridge_token_digest, unique: true
    # Stamped on every authenticated pull; drives the "is your machine
    # connected" hint, never the engine.
    add_column :users, :bridge_seen_at, :datetime
  end
end
