require "test_helper"

class Api::Bridge::SkillControllerTest < ActionDispatch::IntegrationTest
  test "serves the client skill without auth, with the deployment url baked in" do
    get "/api/bridge/skill"
    assert_response :success
    assert_match %r{text/markdown}, response.content_type
    assert_match "name: metis-bridge", response.body
    assert_includes response.body, "go install github.com/chagel/metis/clients/metis@latest"
    assert_includes response.body, "metis install"
    assert_includes response.body, request.base_url
    assert_not_includes response.body, "/api/bridge/mcp", "the daemon is the supported client — no MCP setup"
  end
end
