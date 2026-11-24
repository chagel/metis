require "test_helper"

# Personal routines belong to their user; team routines to every member,
# managed by admins. Both kinds live side by side in one team.
class RoutineScopeTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", password: "password123", display_name: "Ada")
    @member = User.create!(email: "m-#{SecureRandom.hex(4)}@example.com", password: "password123", display_name: "Max")
    @team = Team.create!(name: "Acme")
    @team.memberships.create!(user: @admin, role: :owner)
    @team.memberships.create!(user: @member, role: :member)
    @mine = routine("Max's digest", user: @member, visibility: :personal)
    @shared = routine("Standup", user: @admin, visibility: :team)
  end

  def routine(name, **attrs)
    @team.routines.create!({ name: name, prompt: "go", cron: "0 9 * * *", timezone: "UTC" }.merge(attrs))
  end

  def act_as(user)
    sign_in user
    post switch_team_path(@team), headers: { "HTTP_REFERER" => root_path }
  end

  test "an admin can't see, edit or run a member's personal routine" do
    act_as(@admin)
    get routines_path(tab: "mine")
    assert_no_match(/Max&#39;s digest/, response.body)

    get edit_routine_path(@mine)
    assert_response :not_found
    post run_routine_path(@mine)
    assert_response :not_found
  end

  test "a member manages their own routines and only sees team ones" do
    act_as(@member)
    get routines_path
    assert_select ".board-chip.is-on", text: /My routines/
    assert_select ".conn-name", text: /Max's digest/
    assert_select ".conn-actions", count: 1

    patch toggle_routine_path(@mine)
    assert_not @mine.reload.enabled?

    get routines_path(tab: "team")
    assert_select ".conn-name", text: /Standup/
    assert_select ".conn-sub", text: /Runs as Ada/
    assert_select ".conn-actions", count: 0
    patch toggle_routine_path(@shared)
    assert @shared.reload.enabled?
  end

  test "a member can create a personal routine but not a team one" do
    act_as(@member)
    params = { name: "Mine", prompt: "go", trigger_source: "schedule", cron: "0 9 * * *", timezone: "UTC" }
    post routines_path, params: { routine: params }
    assert @team.routines.named("Mine").first.visibility_personal?

    assert_no_difference -> { @team.routines.count } do
      post routines_path, params: { routine: params.merge(name: "Ours", visibility: "team") }
    end
    patch routine_path(@mine), params: { routine: { visibility: "team" } }
    assert @mine.reload.visibility_personal?
  end

  test "the agent's routine tools follow the same rule" do
    admin_chat = @admin.conversations.create!(team: @team)
    assert_not_includes Agent::RoutineManager.list(admin_chat).map { |r| r[:name] }, @mine.name

    member_chat = @member.conversations.create!(team: @team)
    assert Agent::RoutineManager.create(member_chat, "name" => "Own", "prompt" => "p", "trigger" => "schedule", "cron" => "0 9 * * *")[:ok]
    team_attempt = Agent::RoutineManager.create(member_chat, "name" => "Shared", "prompt" => "p", "trigger" => "schedule", "cron" => "0 9 * * *", "visibility" => "team")
    assert_not team_attempt[:ok]
    assert_not Agent::RoutineManager.update(member_chat, "name" => "Standup", "enabled" => "false")[:ok]
  end
end
