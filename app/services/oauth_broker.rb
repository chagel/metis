# Provider-agnostic OAuth token broker for OauthGrants. Returns the
# current access token for a grant, refreshing through the provider's
# token endpoint when within `REFRESH_LEEWAY` of expiry. Refresh
# writes back via OauthGrant#absorb!. See docs/connectors.md.
#
# Also the single source of truth for the strategy/provider name
# split: Identity stores the omniauth strategy name ("google_oauth2"),
# OauthGrant + catalog use the canonical name ("google"). All
# translation goes through `normalize_provider` / `omniauth_strategy`.
module OauthBroker
  class Error < StandardError; end

  # The provider rejected the refresh token as permanently dead —
  # revoked by the user, expired (e.g. a Testing-status app's 7-day
  # refresh-token life), or superseded. No retry can recover it; only
  # re-consent. Distinct from Error so refresh! can clear the grant
  # instead of leaving it to fail on every turn.
  class InvalidGrantError < Error; end

  CLIENTS = {
    "github" => Clients::Github,
    "google" => Clients::Google
  }.freeze

  STRATEGY_TO_PROVIDER = {
    "github" => "github",
    "google_oauth2" => "google"
  }.freeze

  PROVIDER_TO_STRATEGY = STRATEGY_TO_PROVIDER.invert.freeze

  PROVIDERS = STRATEGY_TO_PROVIDER.values.freeze

  # The base sign-in scope set per provider — the smallest set that
  # lets us identify the user (matching what config/initializers/devise.rb
  # asks for on the bare sign-in flow). Connector-specific scopes are
  # added incrementally on top by the marketplace "Connect" button.
  SIGN_IN_SCOPES = {
    "github" => [ "user:email" ],
    "google" => [ "email", "profile" ]
  }.freeze

  class << self
    def normalize_provider(strategy)
      STRATEGY_TO_PROVIDER[strategy.to_s]
    end

    def omniauth_strategy(provider)
      PROVIDER_TO_STRATEGY[provider.to_s]
    end

    # True when grant.scopes can be trusted as an authoritative
    # statement of what the token can do. False for providers whose
    # OAuth flow doesn't actually carry scopes — GitHub Apps in
    # particular: their OAuth response does not echo OAuth scopes
    # (App permissions configured on the App's settings page are the
    # real gate), so grant.scopes ends up empty/incomplete regardless
    # of what we asked for. Callers must fall back to "grant + token
    # present" instead of `grant.covers?(...)` for these providers.
    # See docs/connectors.md.
    def scope_check_meaningful?(provider)
      provider.to_s != "github"
    end

    # The current access token for the grant, refreshing if needed.
    # A grant whose stored access token is blank (legacy backfill row,
    # partial absorb!) must refresh even when fresh? is true — otherwise
    # we'd hand the MCP server an empty bearer instead of a 401-or-recovery.
    def access_token_for(grant)
      return grant.access_token if grant.fresh? && grant.access_token.present?

      refresh!(grant)
    end

    # The current bearer for `user` on `provider`, refreshed if needed,
    # gated by `required_scopes` (the grant must cover them all). Used by
    # the sandbox runtimes to stage per-turn credentials into the agent's
    # environment without coupling to a Connector record — if the user
    # has the grant and the scope, the agent gets the token. See
    # docs/connectors.md ("Credential pass-through to the sandbox").
    def bearer_for(user:, provider:, required_scopes: [])
      grant = user.oauth_grants.find_by(provider: provider)
      return nil if grant.nil?
      return nil if scope_check_meaningful?(provider) && !grant.covers?(required_scopes)

      access_token_for(grant)
    end

    # Revoke the grant on the provider's side and tear down our copy.
    # Best-effort: a network failure logs and returns rather than
    # blocking the caller (the local delete still happens).
    def revoke(grant)
      client = client_for(grant.provider)
      token = revoke_token_for(grant)
      client.revoke(token) if token.present? && client.respond_to?(:revoke)
    rescue StandardError => error
      Rails.logger.warn(
        "OauthBroker.revoke failed for user=#{grant.user_id} provider=#{grant.provider}: " \
        "#{error.class}: #{error.message}"
      )
    end

    private

    def refresh!(grant)
      raise Error, "grant has no refresh token" if grant.refresh_token.blank?

      response = client_for(grant.provider).refresh(grant.refresh_token)
      grant.absorb!(response)
      grant.access_token
    rescue KeyError => error
      raise Error, "refresh response missing #{error.key}"
    rescue InvalidGrantError
      # The refresh token is dead on the provider's side — drop the grant
      # so the next Connect re-consents and we stop refreshing it every turn.
      Rails.logger.warn(
        "OauthBroker: dropping dead grant user=#{grant.user_id} provider=#{grant.provider} (invalid_grant)"
      )
      grant.destroy
      raise
    end

    def client_for(provider)
      CLIENTS[provider] or raise Error, "unknown oauth provider #{provider.inspect}"
    end

    def revoke_token_for(grant)
      case grant.provider
      when "github"
        grant.access_token
      else
        grant.refresh_token || grant.access_token
      end
    end
  end
end
