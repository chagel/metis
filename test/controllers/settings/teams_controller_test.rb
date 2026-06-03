require "test_helper"

class Settings::TeamsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "owner@example.com", password: "password123")
    sign_in @user
  end

  # Make `team` the active team for the next request via the switcher.
  def act_in(team)
    post switch_team_path(team), headers: { "HTTP_REFERER" => root_path }
  end

  test "show renders the new-team action for the personal workspace" do
    get team_path
    assert_response :success
    assert_select ".team-add .team-pick-name", text: "New team"
  end

  test "the personal workspace lists the shared teams you belong to" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :member)

    get team_path
    assert_response :success
    assert_select ".team-pick-name", text: "Acme"
  end

  test "show lists members for a real team" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :owner)
    act_in(team)

    get team_path
    assert_response :success
    assert_select ".member-row .member-email", text: @user.email
    assert_select ".member-role", text: "Owner"
  end

  test "an admin can rename the team" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :admin)
    act_in(team)

    patch team_path, params: { team: { name: "Acme Corp" } }
    assert_redirected_to team_path
    assert_equal "Acme Corp", team.reload.name
  end

  test "a plain member cannot rename the team" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :member)
    act_in(team)

    patch team_path, params: { team: { name: "Hijacked" } }
    assert_redirected_to team_path
    assert_equal "Acme", team.reload.name
  end

  test "the personal workspace cannot be renamed" do
    patch team_path, params: { team: { name: "Nope" } }
    assert_redirected_to team_path
    assert_not_equal "Nope", @user.personal_team.reload.name
  end

  test "the owner can delete the team and falls back to the personal workspace" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :owner)
    act_in(team)

    assert_difference -> { Team.count }, -1 do
      delete team_path
    end
    assert_redirected_to team_path
    follow_redirect!
    assert_select ".team-add .team-pick-name", text: "New team" # back in the personal workspace
  end

  test "a non-owner cannot delete the team" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :admin)
    act_in(team)

    assert_no_difference -> { Team.count } do
      delete team_path
    end
    assert_redirected_to team_path
  end

  test "the personal workspace cannot be deleted" do
    assert_no_difference -> { Team.count } do
      delete team_path
    end
  end
end
