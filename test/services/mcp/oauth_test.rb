require "test_helper"

class Mcp::OauthTest < ActiveSupport::TestCase
  def metadata
    Mcp::Oauth::Discovery::Metadata.new(
      issuer: "https://auth.example.com", authorization_endpoint: "https://auth.example.com/authorize",
      token_endpoint: "https://auth.example.com/token", registration_endpoint: "https://auth.example.com/register",
      code_challenge_methods: [ "S256" ], scopes_supported: []
    )
  end

  test "Pkce derives an unpadded S256 challenge from the verifier" do
    pkce = Mcp::Oauth::Pkce.new(verifier: "test-verifier-1234567890")
    expected = Base64.urlsafe_encode64(Digest::SHA256.digest("test-verifier-1234567890")).tr("=", "")

    assert_equal expected, pkce.challenge
    assert_equal "S256", pkce.challenge_method
    assert_not_includes pkce.challenge, "="
  end

  test "authorize_url carries PKCE, the resource indicator, and state" do
    url = Mcp::Oauth.authorize_url(metadata,
      client_id: "cid", redirect_uri: "https://metis.test/cb",
      resource: "https://mcp.example.com/mcp", code_challenge: "chal", state: "st8")
    q = Rack::Utils.parse_query(URI(url).query)

    assert_equal "https://auth.example.com/authorize", url.split("?").first
    assert_equal "code", q["response_type"]
    assert_equal "S256", q["code_challenge_method"]
    assert_equal "chal", q["code_challenge"]
    assert_equal "https://mcp.example.com/mcp", q["resource"] # RFC 8707 audience binding
    assert_equal "st8", q["state"]
  end

  test "exchange_code posts the code, verifier, and resource to the token endpoint" do
    captured = {}
    stub = ->(url, payload) { captured[:url] = url; captured[:payload] = payload; { "access_token" => "tok" } }

    with_stub(Mcp::Oauth::Http, :post_form, stub) do
      tokens = Mcp::Oauth.exchange_code(metadata,
        client_id: "cid", code: "authcode", code_verifier: "ver",
        redirect_uri: "https://metis.test/cb", resource: "https://mcp.example.com/mcp")
      assert_equal "tok", tokens["access_token"]
    end

    assert_equal "https://auth.example.com/token", captured[:url]
    assert_equal "authorization_code", captured[:payload][:grant_type]
    assert_equal "ver", captured[:payload][:code_verifier]
    assert_equal "https://mcp.example.com/mcp", captured[:payload][:resource]
  end
end
