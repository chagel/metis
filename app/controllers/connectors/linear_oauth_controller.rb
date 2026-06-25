module Connectors
  # Direct Linear OAuth (linear.app/oauth), separate from the connector's
  # MCP-OAuth: this grants an api.linear.app token the project picker can
  # use to list the member's Linear projects. start → consent at Linear →
  # callback exchanges the code and stores the token on the member's Linear
  # ConnectorCredential. See docs/connectors.md.
  class LinearOauthController < ApplicationController
    # Authorizing has team-level side effects (it captures the connector's
    # linear_organization_id and subscribes the workspace to the app
    # webhook), so it's admin-only like the connector page it launches from.
    before_action :require_team_admin!

    def start
      return redirect_to(connectors_path, alert: t("flash.connectors.linear_oauth.unconfigured")) unless LinearApp::Config.configured?
      return redirect_to(connectors_path, alert: t("flash.connectors.linear_oauth.no_connector")) unless connector

      state = SecureRandom.urlsafe_base64(24)
      session[:linear_oauth] = { "state" => state, "connector_id" => connector.id }

      redirect_to LinearApp::Oauth.authorize_url(redirect_uri: connector_linear_callback_url, state: state),
                  allow_other_host: true
    end

    def callback
      flow = session.delete("linear_oauth") || {}
      return redirect_to(connectors_path, alert: t("flash.connectors.linear_oauth.expired")) unless valid_state?(flow)

      target = current_team.connectors.find_by(id: flow["connector_id"])
      return redirect_to(connectors_path, alert: t("flash.connectors.linear_oauth.no_connector")) unless target
      return redirect_to(edit_connector_path(target), alert: t("flash.connectors.linear_oauth.cancelled")) if params[:code].blank?

      tokens = LinearApp::Oauth.exchange(code: params[:code], redirect_uri: connector_linear_callback_url)
      target.connector_credentials.find_or_initialize_by(user: current_user).store_linear_api!(tokens)
      capture_organization(target, tokens["access_token"])

      redirect_to edit_connector_path(target), notice: t("flash.connectors.linear_oauth.notice")
    rescue LinearApp::Oauth::Error => error
      redirect_to connectors_path, alert: t("flash.connectors.linear_oauth.failed", message: error.message)
    end

    private

    def connector
      @connector ||= current_team.connectors.find_by(catalog_key: "linear")
    end

    # Stash the authorizing workspace's org id so inbound app-webhook
    # deliveries resolve to this team. Best-effort — a Linear blip here
    # mustn't fail an otherwise-successful authorization (the picker still
    # works; only webhook routing waits for the next authorize).
    def capture_organization(target, token)
      org_id = Linear::Api.new(token).organization_id
      target.update!(linear_organization_id: org_id) if org_id.present?
    rescue Linear::Api::Error => error
      Rails.logger.warn("linear org capture failed — #{error.message}")
    end

    def valid_state?(flow)
      flow["state"].present? &&
        ActiveSupport::SecurityUtils.secure_compare(flow["state"], params[:state].to_s)
    end
  end
end
