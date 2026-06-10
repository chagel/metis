require "test_helper"

class Api::Bridge::SkillControllerTest < ActionDispatch::IntegrationTest
  test "serves the client skill without auth, with the deployment url baked in" do
    get "/api/bridge/skill"
    assert_response :success
    assert_match %r{text/markdown}, response.content_type
    assert_match "name: metis-bridge", response.body
    assert_includes response.body, "#{request.base_url}/api/bridge/mcp"
    assert_includes response.body, "submit_result"
  end
end
