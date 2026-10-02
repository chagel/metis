require "test_helper"

class Mcp::Oauth::ProviderTest < ActiveSupport::TestCase
  RESOURCE = "https://mcp.example.com/mcp".freeze
  CALLBACK = "https://metis.test/cb".freeze
  CIMD_URL = "https://metis.test/oauth/mcp-client.json".freeze

  def metadata(cimd: false)
    Mcp::Oauth::Discovery::Metadata.new(
      issuer: "https://auth.example.com", authorization_endpoint: "https://auth.example.com/authorize",
      token_endpoint: "https://auth.example.com/token", registration_endpoint: "https://auth.example.com/register",
      code_challenge_methods: [ "S256" ], scopes_supported: [], client_id_metadata_document_supported: cimd
    )
  end

  # Runs a connect against stubbed discovery, registration (cid-1, cid-2, …),
  # and a token endpoint that answers the client check with `check`.
  def connect(md, client_metadata_url: CIMD_URL, check: -> { { "error" => "never reached" } })
    registrations = 0
    register = ->(_md, redirect_uri:) { Mcp::Oauth::Registration::Client.new(client_id: "cid-#{registrations += 1}", client_secret: nil, raw: {}) }
    token = ->(_url, _payload) { check.call }

    provider = with_stub(Mcp::Oauth::Discovery, :call, ->(_url) { md }) do
      with_stub(Mcp::Oauth::Registration, :call, register) do
        with_stub(Mcp::Oauth::Http, :post_form, token) do
          Mcp::Oauth::Provider.connect(RESOURCE, redirect_uri: CALLBACK, client_metadata_url: client_metadata_url)
        end
      end
    end
    [ provider, registrations ]
  end

  test "uses the CIMD URL as client_id when the server supports it, registering nothing" do
    provider, registrations = connect(metadata(cimd: true))

    assert_equal CIMD_URL, provider.client_id
    assert_equal 0, registrations
    assert_equal 0, McpOauthClient.count
  end

  test "falls back to DCR when the CIMD URL isn't https (a server can't fetch it)" do
    provider, = connect(metadata(cimd: true), client_metadata_url: "http://localhost:3000/oauth/mcp-client.json")

    assert_equal "cid-1", provider.client_id
  end

  test "falls back to a DCR client cached per issuer when the server lacks CIMD" do
    provider, registrations = connect(metadata)

    assert_equal "cid-1", provider.client_id
    assert_equal 1, registrations
    assert_equal "cid-1", McpOauthClient.find_by(issuer: "https://auth.example.com").client_id
  end

  test "reuses the cached client while the token endpoint still knows it" do
    McpOauthClient.create!(issuer: "https://auth.example.com", client_id: "cached")
    invalid_grant = -> { raise Mcp::Oauth::Error, "token -> 400: invalid_grant" }

    provider, registrations = connect(metadata, check: invalid_grant)

    assert_equal "cached", provider.client_id
    assert_equal 0, registrations
  end

  test "replaces a cached client the token endpoint disowns, before the consent page sees it" do
    McpOauthClient.create!(issuer: "https://auth.example.com", client_id: "revoked")
    McpOauthClient.create!(issuer: "https://other.example.com", client_id: "revoked")
    invalid_client = -> { raise Mcp::Oauth::InvalidClient, "token -> 401: invalid_client" }

    provider, registrations = connect(metadata, check: invalid_client)

    assert_equal "cid-1", provider.client_id
    assert_equal 1, registrations
    assert_equal "cid-1", McpOauthClient.find_by(issuer: "https://auth.example.com").client_id
    assert_equal "revoked", McpOauthClient.find_by(issuer: "https://other.example.com").client_id
  end

  test "keeps the cached client when the check is inconclusive" do
    McpOauthClient.create!(issuer: "https://auth.example.com", client_id: "cached")
    network_error = -> { raise Mcp::Oauth::Error, "token -> 502: bad gateway" }

    provider, = connect(metadata, check: network_error)

    assert_equal "cached", provider.client_id
  end

  test "the client check redeems a throwaway code with the cached client's id" do
    md = metadata
    captured = {}
    stub = ->(url, payload) { captured[:url] = url; captured[:payload] = payload; raise Mcp::Oauth::Error, "invalid_grant" }

    with_stub(Mcp::Oauth::Http, :post_form, stub) do
      assert_not Mcp::Oauth::Provider.revoked?(md, "cached", RESOURCE, CALLBACK)
    end

    assert_equal "https://auth.example.com/token", captured[:url]
    assert_equal "authorization_code", captured[:payload][:grant_type]
    assert_equal "cached", captured[:payload][:client_id]
    assert_operator captured[:payload][:code_verifier].length, :>=, 43
  end

  test "resume rebuilds the provider with the client the connect chose" do
    md = metadata(cimd: true)
    captured = {}

    with_stub(Mcp::Oauth::Discovery, :call, ->(_url) { md }) do
      provider = Mcp::Oauth::Provider.resume(RESOURCE, client_id: CIMD_URL)

      url = provider.authorize_url(redirect_uri: CALLBACK, state: "st8", pkce: Mcp::Oauth::Pkce.new(verifier: "v"))
      q = Rack::Utils.parse_query(URI(url).query)
      assert_equal CIMD_URL, q["client_id"]
      assert_equal RESOURCE, q["resource"]

      with_stub(Mcp::Oauth::Http, :post_form, ->(_url, payload) { captured = payload; { "access_token" => "tok" } }) do
        provider.exchange(code: "c", code_verifier: "v", redirect_uri: CALLBACK)
      end
    end

    assert_equal CIMD_URL, captured[:client_id]
    assert_equal RESOURCE, captured[:resource]
  end
end
