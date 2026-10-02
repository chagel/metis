module Mcp
  module Oauth
    # Ties the per-server OAuth bits together for one MCP resource:
    # discovers the server's endpoints, registers a client (DCR), and builds
    # the authorize URL / exchanges the code. The controller drives the
    # browser round-trip; this holds the server-specific knowledge.
    class Provider
      # A fresh client per connect, never a cached one: a server can revoke a
      # registration (Linear has), and a consent page that rejects it never
      # tells us — reconnecting must not reuse it.
      def self.register(resource_url, redirect_uri:)
        metadata = Discovery.call(resource_url)
        new(resource_url, metadata, Registration.call(metadata, redirect_uri: redirect_uri).client_id)
      end

      # The client #register issued for this connect, carried through the session.
      def self.for(resource_url, client_id:)
        new(resource_url, Discovery.call(resource_url), client_id)
      end

      attr_reader :client_id

      def initialize(resource_url, metadata, client_id)
        @resource = resource_url
        @metadata = metadata
        @client_id = client_id
      end

      # Persisted on the credential so a later token refresh is
      # self-contained (no re-discovery per turn).
      def token_endpoint = @metadata.token_endpoint

      def authorize_url(redirect_uri:, state:, pkce:)
        Oauth.authorize_url(@metadata,
          client_id: @client_id,
          redirect_uri: redirect_uri,
          resource: @resource,
          code_challenge: pkce.challenge,
          state: state,
          scope: @metadata.scopes_supported.presence&.join(" "))
      end

      def exchange(code:, code_verifier:, redirect_uri:)
        Oauth.exchange_code(@metadata,
          client_id: @client_id,
          code: code,
          code_verifier: code_verifier,
          redirect_uri: redirect_uri,
          resource: @resource)
      end
    end
  end
end
