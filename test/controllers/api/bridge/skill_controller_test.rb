require "test_helper"

class Api::Bridge::SkillControllerTest < ActionDispatch::IntegrationTest
  test "serves the client skill without auth, with the deployment url baked in" do
    get "/api/bridge/skill"
    assert_response :success
    assert_match %r{text/markdown}, response.content_type
    assert_match "name: metis-bridge", response.body
    assert_includes response.body, request.base_url
  end

  test "documents both the auto daemon and the manual MCP options" do
    get "/api/bridge/skill"
    # Auto — the daemon.
    assert_includes response.body, "go install github.com/chagel/metis/clients/metis@latest"
    assert_includes response.body, "metis install"
    # Manual — the MCP server and its tools.
    assert_includes response.body, "/api/bridge/mcp"
    %w[list_tasks get_next_task report_progress submit_result].each do |tool|
      assert_includes response.body, tool, "manual option should document the #{tool} MCP tool"
    end
  end

  test "points at the Developer settings page for the token, not the old account page" do
    get "/api/bridge/skill"
    assert_includes response.body, "/settings/developer"
    assert_not_includes response.body, "/settings/account"
  end
end
