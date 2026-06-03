# A Metis OAuth client dynamically registered (RFC 7591) with one MCP
# authorization server. Registration is deployment-wide and reused across
# every team/member that connects a server backed by that authorization
# server — so DCR happens once per server, not once per user. The token
# each member receives lives on their ConnectorCredential, not here.
class McpOauthClient < ApplicationRecord
  encrypts :client_secret

  validates :issuer, presence: true, uniqueness: true
  validates :client_id, presence: true

  # Public client (PKCE, no secret) vs confidential (server issued one).
  def public_client?
    client_secret.blank?
  end
end
