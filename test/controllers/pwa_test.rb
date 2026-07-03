require "test_helper"

class PwaTest < ActionDispatch::IntegrationTest
  test "manifest is served unauthenticated as valid json" do
    get pwa_manifest_path(format: :json)

    assert_response :success
    manifest = JSON.parse(response.body)
    assert_equal "Metis", manifest["name"]
    assert_equal "standalone", manifest["display"]
    assert manifest["theme_color"].start_with?("#")
  end

  test "service worker is served unauthenticated" do
    get pwa_service_worker_path(format: :js)

    assert_response :success
  end
end
