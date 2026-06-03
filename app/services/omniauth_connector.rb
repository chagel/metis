# Translates an OmniAuth callback into the durable per-user OAuth
# state metis keeps: one OauthGrant per (user, provider) holding the
# tokens + every scope ever granted, plus a ConnectorCredential
# *marker* for each connector the user has wired through that grant.
#
# Two entry points, called in sequence by the omniauth callback:
#
# * `record_grant` always — the callback ALWAYS arrives with a fresh
#   token bundle for the user; we union those tokens + scopes into
#   their OauthGrant for the provider. Sign-in goes through this and
#   only this; the grant ends up holding just the sign-in scopes.
#
# * `activate_connector` only when the callback was triggered by a
#   "Connect <app>" button (the authorize URL carries `connect=<key>`
#   which omniauth round-trips back as `omniauth.params["connect"]`).
#   The connector's catalog app's required scopes are part of the
#   grant by now (the authorize URL asked for them); we just record
#   the ConnectorCredential marker so McpConfig knows to stage it.
#
# See docs/connectors.md.
class OmniauthConnector
  class << self
    # Absorb the callback's token bundle into the user's OauthGrant
    # for this provider, creating the grant on first sign-in. `provider`
    # is the catalog `oauth_provider` (e.g. "google"), not the omniauth
    # strategy name (`google_oauth2`).
    def record_grant(user, auth, provider:)
      grant = user.oauth_grants.find_or_initialize_by(provider: provider)
      grant.absorb!(token_bundle(auth))
      grant
    end

    # Mark `app` as connected for `user` on `team`: create the
    # ConnectorCredential marker on the team's Connector (creating the
    # Connector too if this is the first team member to wire it). The
    # token lives in the OauthGrant `record_grant` just updated — this row
    # is just the per-member presence signal McpConfig keys off.
    def activate_connector(user, app, auth, team:)
      connector = team.connectors.find_or_initialize_by(catalog_key: app.key)
      connector.update!(name: app.key, transport: app.transport, definition: app.definition)
      credential = connector.connector_credentials.find_or_initialize_by(user: user)
      # Don't blank a previously-set handle if a later callback omits it
      # (Google has no nickname; GitHub does). View falls back to a
      # generic "Your <app> account is connected" when blank.
      credential.external_login = auth.info.nickname if auth.info.nickname.present?
      credential.save!
      connector
    end

    private

    # Shape OmniAuth credentials into the OauthGrant absorb! response
    # shape (matches the direct OAuth code-exchange response).
    def token_bundle(auth)
      credentials = auth.credentials
      expires_in = credentials.expires_at ? credentials.expires_at - Time.current.to_i : nil
      {
        "access_token" => credentials.token,
        "refresh_token" => credentials.refresh_token,
        "expires_in" => expires_in,
        "scope" => oauth_scope(auth)
      }.compact
    end

    def oauth_scope(auth)
      credentials = auth.credentials
      return credentials.scope if credentials.respond_to?(:scope) && credentials.scope.present?

      auth.extra&.[](:scope).presence || auth.extra&.[]("scope").presence
    end
  end
end
