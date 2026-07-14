module Connectors
  # Direct X OAuth 2.0 + PKCE (x.com/i/oauth2/authorize) — X has no
  # omniauth sign-in strategy, so the marketplace Connect button lands
  # here instead of the Devise callback. Per-member like the brokered
  # providers: start → consent at X → callback exchanges the code and
  # absorbs the tokens into the member's (user, "x") OauthGrant; the
  # ConnectorCredential row is just the presence marker McpConfig keys
  # off. The one-time state + PKCE verifier live in the initiator's
  # session, so only that user's browser can complete (or replay) the
  # callback. See docs/connectors.md.
  class XOauthController < ApplicationController
    def start
      return redirect_to(connectors_path, alert: t("flash.connectors.x_oauth.unconfigured")) unless XApp::Config.configured?

      pkce = Mcp::Oauth::Pkce.new
      state = SecureRandom.urlsafe_base64(24)
      session[:x_oauth] = { "state" => state, "verifier" => pkce.verifier }

      redirect_to XApp::Oauth.authorize_url(state: state, code_challenge: pkce.challenge),
                  allow_other_host: true
    end

    def callback
      flow = session.delete("x_oauth") || {}
      return redirect_to(connectors_path, alert: t("flash.connectors.x_oauth.expired")) unless valid_state?(flow)
      return redirect_to(connectors_path, alert: t("flash.connectors.x_oauth.cancelled")) if params[:code].blank?

      tokens = XApp::Oauth.exchange(code: params[:code], code_verifier: flow["verifier"])
      current_user.oauth_grants.find_or_initialize_by(provider: "x").absorb!(tokens)
      activate_connector
      redirect_to connectors_path, notice: t("flash.connectors.x_oauth.notice")
    rescue XApp::Oauth::Error, OauthBroker::Error => error
      Rails.logger.warn("x oauth callback failed for user=#{current_user.id}: #{error.message}")
      redirect_to connectors_path, alert: t("flash.connectors.x_oauth.failed")
    end

    # Removes this member's X access: their grant (revoked on X's side,
    # best-effort) and their presence marker. The team's Connector row
    # stays only while other members still have credentials on it.
    def disconnect
      connector = current_team.connectors.find_by(catalog_key: "x")
      connector&.connector_credentials&.where(user: current_user)&.destroy_all
      if (grant = current_user.oauth_grants.find_by(provider: "x"))
        OauthBroker.revoke(grant)
        grant.destroy
      end
      connector.destroy if connector && connector.connector_credentials.none?
      redirect_to connectors_path, notice: t("flash.connectors.x_oauth.disconnected")
    end

    private

    def valid_state?(flow)
      flow["state"].present? &&
        ActiveSupport::SecurityUtils.secure_compare(flow["state"], params[:state].to_s)
    end

    def activate_connector
      app = ConnectorCatalog.find("x")
      connector = current_team.connectors.find_or_initialize_by(catalog_key: app.key)
      connector.update!(name: app.key, transport: app.transport, definition: app.definition)
      connector.connector_credentials.find_or_create_by!(user: current_user)
    end
  end
end
