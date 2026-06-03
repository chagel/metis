require "test_helper"

class Mcp::Oauth::DiscoveryTest < ActiveSupport::TestCase
  # Mirrors the real chain (Notion/Linear): host-inserted well-known where
  # the resource path follows the well-known name.
  ROUTES = {
    "https://mcp.example.com/.well-known/oauth-protected-resource/mcp" =>
      { "authorization_servers" => [ "https://auth.example.com/mcp" ], "scopes_supported" => [ "read" ] },
    "https://auth.example.com/.well-known/oauth-authorization-server/mcp" => {
      "issuer" => "https://auth.example.com/mcp",
      "authorization_endpoint" => "https://auth.example.com/authorize",
      "token_endpoint" => "https://auth.example.com/token",
      "registration_endpoint" => "https://auth.example.com/register",
      "code_challenge_methods_supported" => [ "S256" ]
    }
  }.freeze

  def with_routes(routes)
    with_stub(Mcp::Oauth::Http, :get_json, ->(url) { routes[url] }) { yield }
  end

  test "walks resource -> protected-resource -> authorization-server metadata" do
    with_routes(ROUTES) do
      md = Mcp::Oauth::Discovery.call("https://mcp.example.com/mcp")

      assert_equal "https://auth.example.com/authorize", md.authorization_endpoint
      assert_equal "https://auth.example.com/token", md.token_endpoint
      assert_equal "https://auth.example.com/register", md.registration_endpoint
      assert_includes md.code_challenge_methods, "S256"
      assert_equal [ "read" ], md.scopes_supported
    end
  end

  test "registration_endpoint is nil when the server advertises no DCR" do
    routes = ROUTES.dup
    routes["https://auth.example.com/.well-known/oauth-authorization-server/mcp"] =
      ROUTES["https://auth.example.com/.well-known/oauth-authorization-server/mcp"].except("registration_endpoint")

    with_routes(routes) do
      assert_nil Mcp::Oauth::Discovery.call("https://mcp.example.com/mcp").registration_endpoint
    end
  end

  test "raises when the resource exposes no protected-resource metadata" do
    with_routes({}) do
      assert_raises(Mcp::Oauth::Error) { Mcp::Oauth::Discovery.call("https://mcp.example.com/mcp") }
    end
  end
end
