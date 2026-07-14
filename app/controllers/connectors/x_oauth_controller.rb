module Connectors
  # X has no omniauth sign-in strategy, so it uses this PKCE callback.
  class XOauthController < ApplicationController
    STATE_TTL = 10.minutes
    def start
      return redirect_to(connectors_path, alert: t("flash.connectors.x_oauth.unconfigured")) unless XApp::Config.configured?

      pkce = Mcp::Oauth::Pkce.new
      state = SecureRandom.urlsafe_base64(24)
      session[:x_oauth] = { "state" => state, "verifier" => pkce.verifier, "issued_at" => Time.current.to_i }

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

    def disconnect
      connector = current_team.connectors.find_by(catalog_key: "x")
      connector.connector_credentials.where(user: current_user).destroy_all if connector
      if (grant = current_user.oauth_grants.find_by(provider: "x"))
        OauthBroker.revoke(grant)
        grant.destroy
      end
      connector.destroy if connector && connector.connector_credentials.none?
      redirect_to connectors_path, notice: t("flash.connectors.x_oauth.disconnected")
    end

    private

    def valid_state?(flow)
      flow["issued_at"].to_i >= STATE_TTL.ago.to_i &&
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
