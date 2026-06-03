module Mcp
  module Oauth
    # RFC 7591 Dynamic Client Registration: register Metis as an OAuth
    # client with the server's authorization server, on the fly — no
    # human pre-registration. Requests a public client (PKCE, no secret)
    # where the server allows it. The returned client_id is meant to be
    # cached and reused deployment-wide per authorization server.
    class Registration
      Client = Data.define(:client_id, :client_secret, :raw)

      def self.call(metadata, redirect_uri:, client_name: "Metis")
        endpoint = metadata.registration_endpoint
        raise Error, "server does not support dynamic client registration" if endpoint.blank?

        body = Http.post_json(endpoint, {
          client_name: client_name,
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
