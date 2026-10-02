module Mcp
  module Oauth
    # Ties the per-server OAuth bits together for one MCP resource:
    # discovers the server's endpoints, picks Metis's client for its
    # authorization server, and builds the authorize URL / exchanges the
    # code. The controller drives the browser round-trip; this holds the
    # server-specific knowledge.
    class Provider
      # A verifier no real flow uses (RFC 7636 wants 43+ chars).
      CHECK_CODE_VERIFIER = ("metis-client-check-" * 3).freeze

      # Starts a connect. Client choice follows the MCP spec's order: a
      # Client ID Metadata Document where the server supports one (nothing
      # registered, nothing to go stale), else a DCR client cached per
      # issuer. CIMD needs an https document URL the server can fetch.
      def self.connect(resource_url, redirect_uri:, client_metadata_url:)
        metadata = Discovery.call(resource_url)
        client_id =
          if metadata.client_id_metadata_document_supported && client_metadata_url.start_with?("https://")
            client_metadata_url
          else
            registered_client(metadata, resource_url, redirect_uri).client_id
          end
        new(resource_url, metadata, client_id)
      end

      # Finishes a connect with the client #connect chose, carried through
      # the session — re-resolving could pick a different one mid-flow.
      def self.resume(resource_url, client_id:)
        new(resource_url, Discovery.call(resource_url), client_id)
      end

      # One McpOauthClient per authorization server, created lazily. A
      # server can revoke it without telling us (Linear did — its consent
      # page just rejects the client_id), so a cached client the token
      # endpoint disowns is replaced before it reaches the browser. The
      # unique index on issuer + a rescue makes the create race-safe.
      def self.registered_client(metadata, resource_url, redirect_uri)
        cached = McpOauthClient.find_by(issuer: metadata.issuer)
        return cached if cached && !revoked?(metadata, cached.client_id, resource_url, redirect_uri)

        cached&.destroy!
        register(metadata, redirect_uri)
      rescue ActiveRecord::RecordNotUnique
        McpOauthClient.find_by!(issuer: metadata.issuer)
      end

      # Redeems a code no flow issued: a token endpoint checks the client
      # first and answers invalid_client for one it doesn't know (RFC 6749
      # §5.2). Any other answer — invalid_grant, a network error — keeps it.
      def self.revoked?(metadata, client_id, resource_url, redirect_uri)
        Oauth.exchange_code(metadata, client_id: client_id, code: "metis-client-check",
                                      code_verifier: CHECK_CODE_VERIFIER, redirect_uri: redirect_uri,
                                      resource: resource_url)
        false
      rescue InvalidClient
        true
      rescue Error
        false
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
