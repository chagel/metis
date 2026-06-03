require "test_helper"

class Mcp::Oauth::ProviderTest < ActiveSupport::TestCase
  RESOURCE = "https://mcp.example.com/mcp".freeze

  def metadata
    Mcp::Oauth::Discovery::Metadata.new(
      issuer: "https://auth.example.com", authorization_endpoint: "https://auth.example.com/authorize",
      token_endpoint: "https://auth.example.com/token", registration_endpoint: "https://auth.example.com/register",
      code_challenge_methods: [ "S256" ], scopes_supported: []
    )
  end

  test "registers a client once per authorization server, then reuses it" do
    md = metadata # capture as a local — the stub lambda runs with self rebound
    registrations = 0
    register = lambda do |_md, redirect_uri:|
      registrations += 1
      Mcp::Oauth::Registration::Client.new(client_id: "cid-#{registrations}", client_secret: nil, raw: {})
    end

    with_stub(Mcp::Oauth::Discovery, :call, ->(_url) { md }) do
      with_stub(Mcp::Oauth::Registration, :call, register) do
        assert_difference("McpOauthClient.count", 1) do
          Mcp::Oauth::Provider.for(RESOURCE, redirect_uri: "https://metis.test/cb")
          Mcp::Oauth::Provider.for(RESOURCE, redirect_uri: "https://metis.test/cb")
        end
      end
    end

    assert_equal 1, registrations, "DCR runs once per authorization server"
    assert_equal "cid-1", McpOauthClient.find_by(issuer: "https://auth.example.com").client_id
  end

  test "authorize_url and exchange carry the resource and client id" do
    md = metadata # captured for the rebound stub lambda
    McpOauthClient.create!(issuer: "https://auth.example.com", client_id: "cid", registration: {})
    captured = {}

    with_stub(Mcp::Oauth::Discovery, :call, ->(_url) { md }) do
      provider = Mcp::Oauth::Provider.for(RESOURCE, redirect_uri: "https://metis.test/cb")

      url = provider.authorize_url(redirect_uri: "https://metis.test/cb", state: "st8",
                                   pkce: Mcp::Oauth::Pkce.new(verifier: "v"))
      q = Rack::Utils.parse_query(URI(url).query)
      assert_equal "cid", q["client_id"]
      assert_equal RESOURCE, q["resource"]

      with_stub(Mcp::Oauth::Http, :post_form, ->(_url, payload) { captured = payload; { "access_token" => "tok" } }) do
        provider.exchange(code: "c", code_verifier: "v", redirect_uri: "https://metis.test/cb")
      end
    end

    assert_equal "cid", captured[:client_id]
    assert_equal RESOURCE, captured[:resource]
  end
end
