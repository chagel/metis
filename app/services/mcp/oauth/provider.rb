module Mcp
  module Oauth
    # Ties the per-server OAuth bits together for one MCP resource:
    # discovers the server's endpoints, reuses (or dynamically registers,
    # once) a deployment-wide client for its authorization server, and
    # builds the authorize URL / exchanges the code. The controller drives
    # the browser round-trip; this holds the server-specific knowledge.
    class Provider
      def self.for(resource_url, redirect_uri:)
        metadata = Discovery.call(resource_url)
        new(resource_url, metadata, registered_client(metadata, redirect_uri))
      end

      # One McpOauthClient per authorization server, created lazily.
      # The unique index on issuer + a rescue makes the lazy create
      # race-safe (two first-connects for the same server).
      def self.registered_client(metadata, redirect_uri)
        McpOauthClient.find_by(issuer: metadata.issuer) || register(metadata, redirect_uri)
      rescue ActiveRecord::RecordNotUnique
        McpOauthClient.find_by!(issuer: metadata.issuer)
      end

      def self.register(metadata, redirect_uri)
        client = Registration.call(metadata, redirect_uri: redirect_uri)
        McpOauthClient.create!(
          issuer: metadata.issuer,
          client_id: client.client_id,
          client_secret: client.client_secret,
          # Drop the secret from the raw blob — it's already in the
          # encrypted client_secret column; the registration jsonb is
          # plaintext, so keeping it here would leak a confidential
          # client's secret at rest.
          registration: client.raw.except("client_secret")
        )
      end

      def initialize(resource_url, metadata, client)
        @resource = resource_url
        @metadata = metadata
        @client = client
      end

      # Persisted on the credential so a later token refresh is
      # self-contained (no re-discovery per turn).
      def token_endpoint = @metadata.token_endpoint
      def client_id = @client.client_id

      def authorize_url(redirect_uri:, state:, pkce:)
        Oauth.authorize_url(@metadata,
          client_id: @client.client_id,
          redirect_uri: redirect_uri,
          resource: @resource,
          code_challenge: pkce.challenge,
          state: state,
          scope: @metadata.scopes_supported.presence&.join(" "))
      end

      def exchange(code:, code_verifier:, redirect_uri:)
        Oauth.exchange_code(@metadata,
          client_id: @client.client_id,
          code: code,
          code_verifier: code_verifier,
          redirect_uri: redirect_uri,
          resource: @resource)
      end
    end
  end
end
