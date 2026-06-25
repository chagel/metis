require "test_helper"

class ConnectorCredentialLinearTest < ActiveSupport::TestCase
  def credential
    @credential ||= ConnectorCredential.create!(
      connector: Connector.create!(team: Team.create!(name: "Acme"), name: "linear",
                                   transport: :http, catalog_key: "linear",
                                   definition: { "url" => "https://mcp.linear.app/mcp" })
    )
  end

  test "store_linear_api! keeps the access token, readable via linear_api_bearer" do
    credential.store_linear_api!({ "access_token" => "lin-tok", "token_type" => "Bearer" })
    assert_equal "lin-tok", credential.reload.linear_api_bearer
  end

  test "linear_api_bearer is nil before authorization" do
    assert_nil credential.linear_api_bearer
  end

  test "the linear api token is independent of the mcp_oauth token" do
    credential.store_mcp_oauth!({ "access_token" => "mcp-tok" }, token_endpoint: "https://e", client_id: "c")
    credential.store_linear_api!({ "access_token" => "api-tok" })

    assert_equal "api-tok", credential.linear_api_bearer
    assert_equal "mcp-tok", credential.reload.mcp_oauth_access_token
  end

  test "linear_api_bearer refreshes an expired token and persists the rotated one" do
    credential.store_linear_api!({ "access_token" => "old", "refresh_token" => "r1", "expires_in" => -1 })
    fresh = { "access_token" => "new", "refresh_token" => "r2", "expires_in" => 86_400 }

    seen = nil
    with_stub(LinearApp::Oauth, :refresh, ->(refresh_token:) { seen = refresh_token; fresh }) do
      assert_equal "new", credential.linear_api_bearer
    end
    assert_equal "r1", seen
    # The rotated token is stored and now fresh — no second refresh.
    assert_equal "new", credential.reload.linear_api_bearer
  end

  test "linear_api_bearer returns nil when the refresh fails" do
    credential.store_linear_api!({ "access_token" => "old", "refresh_token" => "r1", "expires_in" => -1 })

    with_stub(LinearApp::Oauth, :refresh, ->(refresh_token:) { raise LinearApp::Oauth::Error, "boom" }) do
      assert_nil credential.linear_api_bearer
    end
  end
end
