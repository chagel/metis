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

  test "new and edit render the schedule builder" do
    get new_routine_path
    assert_response :success
    assert_select "form.conn-form[data-routine-form-daily-value]"
    assert_select "form.conn-form[data-routine-form-weekly-value]"
    assert_select "form.conn-form[data-routine-form-custom-preview-value]"
    assert_select ".routine-sched-grid"
    assert_select ".routine-day-chips .routine-day-chip", count: 7
    assert_select "[data-routine-form-target='preview']"

    get edit_routine_path(make_routine)
    assert_response :success
    assert_select "input#routine_cron"
  end

  test "create a weekly multi-day routine from a composed cron" do
    post routines_path, params: { routine: {
      name: "Standup", prompt: "go", trigger_source: "schedule",
      cron: "30 9 * * 1,3,5", timezone: "UTC"
    } }
    routine = team.routines.named("Standup").first
    assert_equal "30 9 * * 1,3,5", routine.cron
    assert routine.next_run_at.present?
  end

  test "event-type choices are grouped by connector, from collected events" do
    WebhookEvent.create!(team: team, provider: :github, event_type: "pull_request.opened", payload: {})
    WebhookEvent.create!(team: team, provider: :linear, event_type: "Issue.create", payload: {})
    get new_routine_path
    assert_response :success
    assert_select "select#routine_event_type optgroup[label=?] option[value=?]", "GitHub", "pull_request.opened"
    assert_select "select#routine_event_type optgroup[label=?] option[value=?]", "GitHub", "pull_request.*"
    assert_select "select#routine_event_type optgroup[label=?] option[value=?]", "Linear", "Issue.create"
  end

  test "create a schedule routine" do
    assert_difference -> { team.routines.count }, 1 do
      post routines_path, params: { routine: {
        name: "Daily", prompt: "go", trigger_source: "schedule",
        cron: "0 9 * * *", timezone: "UTC", visibility: "personal"
      } }
    end
    assert_redirected_to routines_path
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

  test "create stores the chosen model in run settings" do
    post routines_path, params: { routine: {
      name: "Daily", prompt: "go", trigger_source: "schedule",
      cron: "0 9 * * *", timezone: "UTC", model: "anthropic/claude-opus-4-8"
    } }
    routine = team.routines.named("Daily").first
    assert_equal "anthropic/claude-opus-4-8", routine.run_settings["model"]
  end

  test "blank model leaves run settings empty" do
    routine = make_routine
    patch routine_path(routine), params: { routine: { name: routine.name, prompt: "x", model: "" } }
    assert_empty routine.reload.run_settings
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

  test "a routine-fired conversation is tagged on its show page" do
    routine = make_routine
    post run_routine_path(routine)
    get conversation_path(routine.conversations.last)
    assert_response :success
    assert_select ".chat-routine-tag", text: /#{routine.name}/
  end

  test "destroy removes the routine" do
    routine = make_routine
    assert_difference -> { team.routines.count }, -1 do
      delete routine_path(routine)
    end
    assert_redirected_to routines_path
  end
end
