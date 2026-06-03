require "test_helper"

class Mcp::Oauth::RegistrationTest < ActiveSupport::TestCase
  def metadata(registration_endpoint: "https://auth.example.com/register")
    Mcp::Oauth::Discovery::Metadata.new(
      issuer: "https://auth.example.com", authorization_endpoint: "https://auth.example.com/authorize",
      token_endpoint: "https://auth.example.com/token", registration_endpoint: registration_endpoint,
      code_challenge_methods: [ "S256" ], scopes_supported: []
    )
  end

  test "registers a public client and returns its id" do
    captured = {}
    stub = lambda do |url, payload|
      captured[:url] = url
      captured[:payload] = payload
      { "client_id" => "abc123", "token_endpoint_auth_method" => "none" }
    end

    with_stub(Mcp::Oauth::Http, :post_json, stub) do
      client = Mcp::Oauth::Registration.call(metadata, redirect_uri: "https://metis.test/connectors/oauth/callback")
      assert_equal "abc123", client.client_id
      assert_nil client.client_secret # public client — nothing secret to store
    end

    assert_equal "https://auth.example.com/register", captured[:url]
    assert_includes captured[:payload][:redirect_uris], "https://metis.test/connectors/oauth/callback"
    assert_equal "none", captured[:payload][:token_endpoint_auth_method]
    assert_includes captured[:payload][:grant_types], "refresh_token"
  end

  test "raises when the server has no registration endpoint" do
    assert_raises(Mcp::Oauth::Error) do
      Mcp::Oauth::Registration.call(metadata(registration_endpoint: nil), redirect_uri: "https://metis.test/cb")
    end
  end
end
