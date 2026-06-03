class CreateMcpOauthClients < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_oauth_clients do |t|
      # The authorization server we registered with (RFC 8414 issuer).
      # One dynamically-registered client per AS, reused deployment-wide.
      t.string :issuer, null: false
      t.string :client_id, null: false
      t.text :client_secret # encrypted; null for public (PKCE) clients
      t.jsonb :registration, default: {}, null: false

      t.timestamps
    end

    add_index :mcp_oauth_clients, :issuer, unique: true
  end
end
