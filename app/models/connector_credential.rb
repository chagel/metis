# A per-member presence marker on a team's Connector. For OAuth-shaped
# connectors, the bearer the MCP server will see is *not* stored here —
# it lives in the user's OauthGrant for the connector's provider, and
# this row's existence just records "this member wired this connector
# up". For token-shaped connectors, the secret IS stored here (in the
# `headers` envelope on the encrypted `credentials` column), because
# there's no per-provider grant to share.
#
# A row with no user is the team's shared credential (a service account
# the whole team uses, only meaningful for token-auth connectors); a
# row with a user is that member's own. The runtime resolves one per
# member when staging `.mcp.json`. See docs/connectors.md.
class ConnectorCredential < ApplicationRecord
  belongs_to :connector
  belongs_to :user, optional: true

  encrypts :credentials

  validates :user_id, uniqueness: { scope: :connector_id }

  # The header bag (`Authorization` → "Bearer xyz") to merge into the
  # connector's `.mcp.json` entry. Token-auth connectors store these
  # directly; OAuth-shaped connectors return an empty hash here — the
  # runtime projects the live access token (from OauthGrant) through
  # the catalog's credential format.
  def credential_map
    envelope["headers"] || {}
  end

  def credential_map=(values)
    write_envelope("headers", values || {})
  end

  # The per-user OauthGrant this connector's bearer comes from, or nil
  # if no grant exists or this isn't an OAuth-shaped connector. Looked
  # up by (user, catalog_app.oauth_provider); a single grant covers
  # every connector wired to the same provider.
  def oauth_grant
    return nil if user.nil?

    provider = connector&.catalog_app&.oauth_provider
    return nil if provider.blank?

    user.oauth_grants.find_by(provider: provider)
  end

  # True when this is an OAuth-shaped connector AND the user has a
  # grant that the runtime can hand the agent as a usable bearer.
  # For providers where OAuth scopes are meaningful (Google, Linear),
  # the grant must cover the catalog's required scopes. For
  # GitHub Apps the OAuth response carries no scopes — presence of a
  # token is the only gate we have; install-coverage is governed
  # server-side by the App's installation, not by us
  # (see docs/connectors.md, OauthBroker.scope_check_meaningful?).
  def oauth_ready?
    grant = oauth_grant
    return false if grant.nil? || grant.access_token.blank?
    return true unless OauthBroker.scope_check_meaningful?(grant.provider)

    grant.covers?(connector.catalog_app.oauth_scopes)
  end

  # MCP-OAuth (Dynamic Client Registration) connectors store their
  # per-member token here directly — unlike the brokered providers, whose
  # tokens live in an OauthGrant (those are pinned to OauthBroker::PROVIDERS,
  # so an arbitrary MCP server can't reuse them). The `credentials` column
  # is encrypted, so the token is encrypted at rest. token_endpoint +
  # client_id are kept alongside so refresh is self-contained (no
  # re-discovery per turn); refresh_token is preserved when a refresh
  # response omits a new one.
  def store_mcp_oauth!(tokens, token_endpoint:, client_id:, at: Time.current)
    prior = mcp_oauth_data
    expires_in = tokens["expires_in"]
    write_envelope("mcp_oauth", {
      "access_token" => tokens["access_token"],
      "refresh_token" => tokens["refresh_token"].presence || prior["refresh_token"],
      "expires_at" => (expires_in.present? ? (at + expires_in.to_i.seconds).iso8601 : nil),
      "token_endpoint" => token_endpoint,
      "client_id" => client_id
    }.compact)
    save!
  end

  def mcp_oauth_access_token
    mcp_oauth_data["access_token"]
  end

  # A usable bearer for the MCP server: the stored token if still fresh,
  # otherwise a refresh. nil means the member must reconnect (no token, or
  # the refresh failed) — the caller drops the connector from .mcp.json.
  def mcp_oauth_bearer
    data = mcp_oauth_data
    return nil if data["access_token"].blank?
    return data["access_token"] unless mcp_oauth_expired?(data)

    refresh_mcp_oauth!(data)
  end

  private

  def mcp_oauth_data
    envelope["mcp_oauth"] || {}
  end

  def mcp_oauth_expired?(data)
    data["expires_at"].present? && Time.iso8601(data["expires_at"]) <= 1.minute.from_now
  end

  def refresh_mcp_oauth!(data)
    return nil if data["refresh_token"].blank? || data["token_endpoint"].blank?

    tokens = Mcp::Oauth.refresh(
      token_endpoint: data["token_endpoint"], client_id: data["client_id"],
      refresh_token: data["refresh_token"], resource: connector.definition["url"]
    )
    store_mcp_oauth!(tokens, token_endpoint: data["token_endpoint"], client_id: data["client_id"])
    tokens["access_token"]
  rescue Mcp::Oauth::Error => error
    Rails.logger.warn("ConnectorCredential #{id}: MCP-OAuth refresh failed — #{error.message}")
    nil
  end

  def envelope
    credentials.present? ? JSON.parse(credentials) : {}
  end

  def write_envelope(key, value)
    self.credentials = envelope.merge(key => value).to_json
  end
end
