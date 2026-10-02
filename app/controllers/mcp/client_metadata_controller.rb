# Metis's OAuth Client ID Metadata Document (MCP spec, CIMD). Its URL is the
# client_id Metis presents to servers that support CIMD; they fetch it to
# learn the client's name and redirect URI. A machine endpoint: public, and
# outside ApplicationController so allow_browser can't turn a fetcher away.
class Mcp::ClientMetadataController < ActionController::Base
  def show
    expires_in 1.hour, public: true
    render json: {
      client_id: mcp_client_metadata_url,
      client_name: Mcp::Oauth::CLIENT_NAME,
      client_uri: root_url,
      logo_uri: "#{root_url}icon.png",
      redirect_uris: [ connector_oauth_callback_url ],
      grant_types: %w[authorization_code refresh_token],
      response_types: %w[code],
      token_endpoint_auth_method: "none"
    }
  end
end
