module Mcp
  module Oauth
    # RFC 7591 Dynamic Client Registration: register Metis as an OAuth
    # client with the server's authorization server, on the fly — no
    # human pre-registration. Requests a public client (PKCE, no secret)
    # where the server allows it. The returned client_id is meant to be
    # cached and reused deployment-wide per authorization server. The MCP
    # spec deprecates DCR — Provider uses it only where the server lacks
    # Client ID Metadata Document support.
    class Registration
      Client = Data.define(:client_id, :client_secret, :raw)
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

      def self.call(metadata, redirect_uri:, client_name: CLIENT_NAME)
        endpoint = metadata.registration_endpoint
        raise Error, "server does not support dynamic client registration" if endpoint.blank?

        body = Http.post_json(endpoint, {
          client_name: client_name,
          # Required by the MCP spec: an OIDC server defaults to "web" and may
          # reject a localhost redirect registered as one.
          application_type: LOOPBACK_HOSTS.include?(URI(redirect_uri).hostname) ? "native" : "web",
          redirect_uris: [ redirect_uri ],
          grant_types: %w[authorization_code refresh_token],
          response_types: %w[code],
          token_endpoint_auth_method: "none"
        })

        Client.new(
          client_id: body.fetch("client_id"),
          client_secret: body["client_secret"],
          raw: body
        )
      end
    end
  end
end
