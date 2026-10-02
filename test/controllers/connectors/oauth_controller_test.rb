require "test_helper"

class Connectors::OauthControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  # Stands in for Mcp::Oauth::Provider — keeps the test off the network.
  class FakeProvider
    def authorize_url(**)
      "https://auth.example.com/authorize?x=1"
    end

    def exchange(**)
      { "access_token" => "tok-123", "refresh_token" => "rt-9", "expires_in" => 3600 }
    end

    def initialize(client_id = "cid")
      @client_id = client_id
    end

    def token_endpoint = "https://auth.example.com/token"
    attr_reader :client_id
  end

  setup do
    @user = User.create!(email: "oc-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in @user
  end

  # Each start registers a new client (cid-1, cid-2, …); the callback rebuilds
  # the provider from the client id carried in the session.
  def with_provider
    registered = 0
    callback_client_ids = @callback_client_ids = []
    register = ->(_url, redirect_uri:) { FakeProvider.new("cid-#{registered += 1}") }
    resume = ->(_url, client_id:) { callback_client_ids << client_id; FakeProvider.new(client_id) }
    with_stub(Mcp::Oauth::Provider, :register, register) do
      with_stub(Mcp::Oauth::Provider, :for, resume) { yield }
    end
  end

  test "start redirects to the authorization URL and stashes PKCE + state" do
    with_provider { post connector_oauth_start_path("notion") }

    assert_redirected_to "https://auth.example.com/authorize?x=1"
    flow = session[:mcp_oauth]
    assert_equal "notion", flow["catalog_key"]
    assert flow["state"].present?
    assert flow["verifier"].present?
  end

  test "every start registers a fresh client, so a revoked one is never reused" do
    with_provider do
      post connector_oauth_start_path("notion")
      assert_equal "cid-1", session[:mcp_oauth]["client_id"]

      post connector_oauth_start_path("notion")
      assert_equal "cid-2", session[:mcp_oauth]["client_id"]
    end
  end

  test "start rejects an unknown or non-mcp_oauth connector" do
    with_provider { post connector_oauth_start_path("github") } # github is brokered oauth, not mcp_oauth
    assert_redirected_to connectors_path
    assert_nil session[:mcp_oauth]
  end

  test "callback exchanges the code and stores the token on the member's credential" do
    with_provider do
      post connector_oauth_start_path("notion")
      state = session[:mcp_oauth]["state"]

      assert_difference("Connector.count", 1) do
        get connector_oauth_callback_path, params: { code: "authcode", state: state }
      end
    end

    assert_redirected_to connectors_path
    assert_equal [ "cid-1" ], @callback_client_ids
    connector = @user.personal_team.connectors.find_by(catalog_key: "notion")
    assert_equal "tok-123", connector.credential_for(@user).mcp_oauth_access_token
  end

  test "per-instance start resolves the supplied URL and stashes it" do
    with_provider do
      post connector_oauth_start_path("metabase"), params: { inputs: { instance_url: "https://mb.example.com" } }
    end

    assert_redirected_to "https://auth.example.com/authorize?x=1"
    assert_equal "https://mb.example.com/api/mcp", session[:mcp_oauth]["resource"]
  end

  test "per-instance start without a URL bounces back to the connect form" do
    with_provider { post connector_oauth_start_path("metabase") } # no inputs
    assert_redirected_to new_connector_path(app: "metabase")
    assert_nil session[:mcp_oauth]
  end

  test "per-instance callback creates the connector at the resolved URL" do
    with_provider do
      post connector_oauth_start_path("metabase"), params: { inputs: { instance_url: "https://mb.example.com" } }
      state = session[:mcp_oauth]["state"]
      get connector_oauth_callback_path, params: { code: "authcode", state: state }
    end

    connector = @user.personal_team.connectors.find_by(catalog_key: "metabase")
    assert_equal "https://mb.example.com/api/mcp", connector.definition["url"]
    assert_equal "tok-123", connector.credential_for(@user).mcp_oauth_access_token
  end

  test "callback rejects a mismatched state and stores nothing" do
    with_provider do
      post connector_oauth_start_path("notion")
      assert_no_difference("Connector.count") do
        get connector_oauth_callback_path, params: { code: "authcode", state: "forged" }
      end
    end
    assert_redirected_to connectors_path
  end
end
