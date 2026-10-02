require "test_helper"

class Mcp::ClientMetadataControllerTest < ActionDispatch::IntegrationTest
  test "serves the CIMD document unauthenticated, its client_id the document's own URL" do
    get mcp_client_metadata_url

    assert_response :success
    doc = JSON.parse(response.body)
    assert_equal mcp_client_metadata_url, doc["client_id"]
    assert_equal "Metis", doc["client_name"]
    assert_equal [ connector_oauth_callback_url ], doc["redirect_uris"]
    assert_equal "none", doc["token_endpoint_auth_method"]
    assert_match "public", response.headers["Cache-Control"]
  end

  test "serves server-side fetchers whatever their user agent" do
    get mcp_client_metadata_url, headers: { "User-Agent" => "Mozilla/5.0 (Windows NT 6.1; MSIE 9.0)" }

    assert_response :success
  end
end
