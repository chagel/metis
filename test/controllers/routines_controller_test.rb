require "test_helper"

class RoutinesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "rc-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in @user
  end

  def team = @user.personal_team

  def make_routine(**attrs)
    team.routines.create!({
      user: @user, name: "Standup", prompt: "hi", trigger_source: :schedule,
      cron: "0 9 * * *", timezone: "UTC"
    }.merge(attrs))
  end

  test "index lists the team's routines" do
    make_routine
    get routines_path
    assert_response :success
    assert_select ".conn-list .conn-name", text: /Standup/
  end

  test "index empty state" do
    get routines_path
    assert_response :success
    assert_select ".pane-empty"
  end

  test "new and edit render the form" do
    get new_routine_path
    assert_response :success
    assert_select "form.conn-form"

    get edit_routine_path(make_routine)
    assert_response :success
    assert_select "input#routine_cron"
  end

  test "create a schedule routine" do
    assert_difference -> { team.routines.count }, 1 do
      post routines_path, params: { routine: {
        name: "Daily", prompt: "go", trigger_source: "schedule",
        cron: "0 9 * * *", timezone: "UTC", visibility: "personal"
      } }
    end
    assert_redirected_to edit_routine_path(team.routines.named("Daily").first)
  end

  test "create with an invalid cron re-renders" do
    post routines_path, params: { routine: {
      name: "Bad", prompt: "go", trigger_source: "schedule", cron: "nope", timezone: "UTC"
    } }
    assert_response :unprocessable_entity
  end

  test "create a webhook routine stores cooldown in trigger_config" do
    post routines_path, params: { routine: {
      name: "OnPR", prompt: "go", trigger_source: "webhook",
      event_type: "pull_request.opened", cooldown_seconds: "120"
    } }
    routine = team.routines.named("OnPR").first
    assert_equal 120, routine.cooldown_seconds
  end

  test "toggle flips enabled" do
    routine = make_routine(enabled: true)
    patch toggle_routine_path(routine)
    assert_not routine.reload.enabled?
  end

  test "run fires the routine and redirects to its conversation" do
    routine = make_routine
    assert_difference -> { @user.conversations.count }, 1 do
      post run_routine_path(routine)
    end
    assert_redirected_to conversation_path(routine.conversations.last)
  end

  test "destroy removes the routine" do
    routine = make_routine
    assert_difference -> { team.routines.count }, -1 do
      delete routine_path(routine)
    end
    assert_redirected_to routines_path
  end
end
