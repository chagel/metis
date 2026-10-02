class DropMcpOauthClients < ActiveRecord::Migration[8.1]
  def change
    drop_table :mcp_oauth_clients do |t|
      t.string :issuer, null: false
      t.string :client_id, null: false
      t.text :client_secret
      t.jsonb :registration, null: false, default: {}
      t.timestamps
      t.index :issuer, unique: true
    end
  end
end
