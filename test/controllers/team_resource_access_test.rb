require "test_helper"

# Shared team tools (skills, connectors, projects): members use them,
# only admins/owners curate them (docs/tenancy.md).
class TeamResourceAccessTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = Team.create!(name: "Acme")
    @owner.memberships.create!(team: @team, role: :owner)
    @member = User.create!(email: "m-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team.memberships.create!(user: @member, role: :member)
  end

  def act_as(user)
    sign_in user
    post switch_team_path(@team), headers: { "HTTP_REFERER" => root_path }
  end

  test "a member can view the team's skills, projects, and connectors" do
    act_as(@member)
    get skills_path
    assert_response :success
    get projects_path
    assert_response :success
    get connectors_path
    assert_response :success
  end

  test "a member cannot open the new-skill form" do
    act_as(@member)
    get new_skill_path
    assert_redirected_to team_path
  end

  test "a member cannot create a skill" do
    act_as(@member)
    assert_no_difference -> { @team.skills.count } do
      post skills_path, params: { skill: { slug: "x", description: "y" } }
    end
    assert_redirected_to team_path
  end

  test "a member cannot delete a skill" do
    skill = @team.skills.create!(slug: "keep", description: "d")
    act_as(@member)
    assert_no_difference -> { @team.skills.count } do
      delete skill_path(skill)
    end
  end

  test "a member cannot open the new-project or new-connector forms" do
    act_as(@member)
    get new_project_path
    assert_redirected_to team_path
    get new_connector_path
    assert_redirected_to team_path
  end

  test "a member cannot enable the github bot on a connector" do
    connector = @team.connectors.create!(catalog_key: "github", name: "github",
                                         transport: :http, definition: { "url" => "https://mcp.example/" })
    act_as(@member)
    patch connector_path(connector), params: { connector: { bot_enabled: "1" } }

    assert_redirected_to team_path
    assert_not connector.reload.bot_enabled?
  end

  test "an admin can curate the team's tools" do
    admin = User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team.memberships.create!(user: admin, role: :admin)
    act_as(admin)

    get new_skill_path
    assert_response :success
    assert_difference -> { @team.skills.count }, 1 do
      post skills_path, params: { skill: { slug: "summarize", description: "d" } }
    end
  end
end
