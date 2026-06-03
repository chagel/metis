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
      return redirect_to(connectors_path, alert: "Unknown connector.") unless app&.mcp_oauth?

      provider = Mcp::Oauth::Provider.for(app.definition["url"], redirect_uri: connector_oauth_callback_url)
      pkce = Mcp::Oauth::Pkce.new
      state = SecureRandom.urlsafe_base64(24)
      session[:mcp_oauth] = {
        "state" => state, "verifier" => pkce.verifier,
        "catalog_key" => app.key, "team_id" => current_team.id
      }

      redirect_to provider.authorize_url(redirect_uri: connector_oauth_callback_url, state: state, pkce: pkce),
                  allow_other_host: true
    rescue Mcp::Oauth::Error => error
      redirect_to connectors_path, alert: "Couldn't start that connection: #{error.message}"
    end

    def callback
      flow = session.delete("mcp_oauth") || {}
      return redirect_to(connectors_path, alert: "That connection expired — try again.") unless valid_state?(flow)
      return redirect_to(connectors_path, alert: "Connection was cancelled.") if params[:code].blank?

      app = ConnectorCatalog.find(flow["catalog_key"])
      team = current_user.teams.find_by(id: flow["team_id"]) || current_user.personal_team
      provider = Mcp::Oauth::Provider.for(app.definition["url"], redirect_uri: connector_oauth_callback_url)
      tokens = provider.exchange(code: params[:code], code_verifier: flow["verifier"],
                                 redirect_uri: connector_oauth_callback_url)

      activate(team, app, provider, tokens)
      redirect_to connectors_path, notice: "#{app.name} connected."
    rescue Mcp::Oauth::Error => error
      redirect_to connectors_path, alert: "Couldn't finish that connection: #{error.message}"
    end

    private

    def valid_state?(flow)
      flow["state"].present? &&
        ActiveSupport::SecurityUtils.secure_compare(flow["state"], params[:state].to_s)
    end

    # Land the connector on the team (creating the Connector row on first
    # connect) and store this member's token on their credential.
    def activate(team, app, provider, tokens)
      connector = team.connectors.find_or_initialize_by(catalog_key: app.key)
      connector.update!(name: app.key, transport: app.transport, definition: app.definition)
      credential = connector.connector_credentials.find_or_initialize_by(user: current_user)
      credential.store_mcp_oauth!(tokens, token_endpoint: provider.token_endpoint, client_id: provider.client_id)
    end
  end
end
