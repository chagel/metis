module Connectors
  # The MCP-OAuth connect flow (Dynamic Client Registration). Unlike the
  # brokered omniauth providers, these servers self-register and we drive
  # the auth-code + PKCE dance ourselves: start → consent at the server →
  # callback exchanges the code and stores the member's token on their
  # ConnectorCredential. See docs/mcp-oauth-connectors.md.
  class OauthController < ApplicationController
    # start writes session state for the round-trip; the PKCE verifier
    # stays server-side, the opaque `state` guards the callback.
    def start
      app = ConnectorCatalog.find(params[:catalog_key])
      return redirect_to(connectors_path, alert: t("flash.connectors.oauth.start.unknown")) unless app&.mcp_oauth?

      # Fixed-URL servers (Notion) resolve to their catalog URL; per-instance
      # servers (Metabase) resolve from the user-supplied `inputs`.
      resource = resolved_url(app)
      if resource.nil?
        return redirect_to new_connector_path(app: app.key),
                           alert: t("flash.connectors.oauth.start.invalid_url", name: app.name)
      end

      provider = Mcp::Oauth::Provider.for(resource, redirect_uri: connector_oauth_callback_url)
      pkce = Mcp::Oauth::Pkce.new
      state = SecureRandom.urlsafe_base64(24)
      session[:mcp_oauth] = {
        "state" => state, "verifier" => pkce.verifier,
        "catalog_key" => app.key, "team_id" => current_team.id, "resource" => resource
      }

      redirect_to provider.authorize_url(redirect_uri: connector_oauth_callback_url, state: state, pkce: pkce),
                  allow_other_host: true
    rescue Mcp::Oauth::Error => error
      redirect_to connectors_path, alert: t("flash.connectors.oauth.start.failed", message: error.message)
    end

    def callback
      flow = session.delete("mcp_oauth") || {}
      return redirect_to(connectors_path, alert: t("flash.connectors.oauth.callback.expired")) unless valid_state?(flow)
      return redirect_to(connectors_path, alert: t("flash.connectors.oauth.callback.cancelled")) if params[:code].blank?

      app = ConnectorCatalog.find(flow["catalog_key"])
      team = current_user.teams.find_by(id: flow["team_id"]) || current_user.personal_team
      resource = flow["resource"]
      provider = Mcp::Oauth::Provider.for(resource, redirect_uri: connector_oauth_callback_url)
      tokens = provider.exchange(code: params[:code], code_verifier: flow["verifier"],
                                 redirect_uri: connector_oauth_callback_url)

      activate(team, app, provider, tokens, resource)
      redirect_to connectors_path, notice: t("flash.connectors.oauth.callback.notice", name: app.name)
    rescue Mcp::Oauth::Error => error
      redirect_to connectors_path, alert: t("flash.connectors.oauth.callback.failed", message: error.message)
    end

    private

    def valid_state?(flow)
      flow["state"].present? &&
        ActiveSupport::SecurityUtils.secure_compare(flow["state"], params[:state].to_s)
    end

    # The MCP server URL to authenticate against: the catalog definition
    # with any `%{input}` placeholders filled from the user's params. nil
    # when a placeholder is left unfilled or the result isn't an https URL.
    def resolved_url(app)
      url = app.resolved_definition(input_params(app))["url"].to_s.strip
      return nil if url.blank? || url.include?("%{")

      uri = begin
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end
      uri.is_a?(URI::HTTPS) ? url : nil
    end

    def input_params(app)
      raw = params[:inputs]
      return {} if raw.blank?

      raw.permit(*app.inputs.map { |input| input["key"] }).to_h
    end

    # Land the connector on the team (creating the Connector row on first
    # connect, with the resolved server URL) and store this member's token.
    def activate(team, app, provider, tokens, resource)
      connector = team.connectors.find_or_initialize_by(catalog_key: app.key)
      connector.update!(name: app.key, transport: app.transport,
                        definition: app.definition.merge("url" => resource))
      credential = connector.connector_credentials.find_or_initialize_by(user: current_user)
      credential.store_mcp_oauth!(tokens, token_endpoint: provider.token_endpoint, client_id: provider.client_id)
    end
  end
end
