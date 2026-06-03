module Mcp
  # OAuth client for remote MCP servers that authenticate via the MCP
  # authorization spec — RFC 9728 protected-resource metadata, RFC 8414
  # authorization-server metadata, RFC 7591 Dynamic Client Registration,
  # OAuth 2.1 authorization-code + PKCE, and RFC 8707 resource indicators.
  #
  # The point: connect to any DCR-capable MCP server (Notion, Linear,
  # Stripe, …) with no pre-registered per-provider app — discover →
  # register a client on the fly → run consent in the browser → store a
  # per-member token → inject it as the connector's bearer. See
  # docs/mcp-oauth-connectors.md.
  module Oauth
    Error = Class.new(StandardError)

    module_function

    # The browser-facing authorization URL (OAuth 2.1 auth-code + PKCE).
    # `resource` is the MCP server URL — RFC 8707 binds the issued token
    # to that audience; MCP servers reject tokens minted without it.
    def authorize_url(metadata, client_id:, redirect_uri:, resource:, code_challenge:, state:, scope: nil)
      query = {
        response_type: "code",
        client_id: client_id,
        redirect_uri: redirect_uri,
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        resource: resource,
        state: state
      }
      query[:scope] = scope if scope.present?

      uri = URI(metadata.authorization_endpoint)
      uri.query = URI.encode_www_form(query)
      uri.to_s
    end

    # Exchange the callback's authorization code for tokens. Returns the
    # raw token response (access_token, refresh_token, expires_in, …).
    def exchange_code(metadata, client_id:, code:, code_verifier:, redirect_uri:, resource:)
      Http.post_form(metadata.token_endpoint, {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: client_id,
        code_verifier: code_verifier,
        resource: resource
      })
    end

    # Refresh an expired access token. The token_endpoint + client_id are
    # persisted on the credential, so this needs no re-discovery.
    def refresh(token_endpoint:, client_id:, refresh_token:, resource:)
      Http.post_form(token_endpoint, {
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: client_id,
        resource: resource
      })
    end
  end
end
