require "test_helper"

class HunchesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "hc-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    sign_in @user
  end

  def hunch(**attrs)
    Hunch.create!({ user: @user, team: @team, title: "Draft reply", body: "Hi Acme,",
                    evidence: [ { "url" => "https://example.com" } ] }.merge(attrs))
  end

  test "index lists ready hunches but not past ones" do
    hunch
    hunch(title: "Old", status: :expired)
    get hunches_path

    assert_response :success
    assert_select ".hunch .hunch-title", text: "Draft reply"
    assert_select ".hunch .hunch-title", text: "Old", count: 0
  end

  test "useful records the outcome without starting a chat" do
    item = hunch
    assert_no_difference -> { @user.conversations.count } do
      patch useful_hunch_path(item), as: :turbo_stream
    end
    assert item.reload.used?
  end

  test "continue in chat attaches the hunch and counts it once the message is sent" do
    item = hunch
    get root_path(hunch: item.id)
    assert_select "input[type=hidden][name=hunch_id][value='#{item.id}']"
    assert_select ".composer .auto-chip", text: /Hunch: Draft reply/
    assert item.reload.ready?

    post conversations_path, params: { hunch_id: item.id, content: "Send it to Acme" }
    message = @user.conversations.order(:id).last.messages.user.first.content
    assert_match "Hi Acme,", message
    assert_match "Send it to Acme", message
    assert item.reload.used?
  end

  test "dismiss records the outcome and reason" do
    item = hunch
    patch dismiss_hunch_path(item), params: { reason: "already_done" }

    assert item.reload.dismissed?
    assert_equal "Already done", item.dismiss_reason
  end

  test "another user's hunch is not found" do
    other = User.create!(email: "hc-o-#{SecureRandom.hex(4)}@example.com", password: "password123")
    item = Hunch.create!(user: other, team: other.personal_team, title: "T", body: "B")
    patch dismiss_hunch_path(item)
    assert_response :not_found
  end

  test "read my mind fires the foresight routine" do
    assert_difference -> { @user.conversations.count } do
      post read_my_mind_hunches_path
    end
    assert_redirected_to hunches_path
    assert @user.conversations.order(:id).last.routine.foresight?
  end

  test "the sidebar lists directions with ready counts and filters by one" do
    payments = Direction.create!(user: @user, team: @team, title: "Payments")
    hiring = Direction.create!(user: @user, team: @team, title: "Hiring")
    hunch(direction: payments)
    hunch(title: "Hiring brief", direction: hiring)

    get hunches_path(direction: payments.id)
    assert_select ".hnav .hnav-item.on .hnav-name", text: "Payments"
    assert_select ".hnav .hnav-item .hnav-name", text: "Hiring"
    assert_select ".hnav-tabs .convo-tab.on", text: "Ready"
    assert_select ".hdir .hdir-title", text: "Payments"
    assert_select ".hdir .switch[aria-checked=true][aria-label='Payments active'][title='Pause Payments']"
    assert_select ".hunch .hunch-title", count: 1
    assert_select ".hunch .hunch-meta a.hunch-source[href='#{hunches_path(direction: payments.id)}']", text: "Payments"
  end

  test "a hunch from a goal says which goal on its card" do
    goal = UserMemory.create!(user: @user, team: @team, content: "Straight 220-yard drives", kind: :goal)
    hunch(title: "Range scorecard", source_memory: goal)
    get hunches_path

    assert_select ".hunch .hunch-meta a.hunch-source[href='#{memories_path(kind: "goal", highlight: goal.id)}']",
                  text: "Goal: Straight 220-yard drives"
  end

  test "history shows past hunches with their outcome" do
    hunch(title: "Done one", status: :used)
    hunch(title: "Still ready")
    get hunches_path(view: "history")

    assert_select ".hunch .hunch-title", text: "Done one"
    assert_select ".hunch .hunch-title", text: "Still ready", count: 0
    assert_select ".hunch .badge", text: "Used"
    assert_select ".hnav-tabs .convo-tab.on", text: "History"
  end

  test "a dismiss reason chip records its label; free text works too" do
    chip = hunch
    patch dismiss_hunch_path(chip), params: { reason: "wrong_timing" }
    assert_equal "Wrong timing", chip.reload.dismiss_reason

    typed = hunch
    patch dismiss_hunch_path(typed), params: { reason_text: "Covered elsewhere" }
    assert_equal "Covered elsewhere", typed.reload.dismiss_reason
  end

  test "read my mind on a direction focuses the run on it" do
    direction = Direction.create!(user: @user, team: @team, title: "Payments")
    post read_my_mind_hunches_path(direction_id: direction.id)

    assert_redirected_to hunches_path(direction: direction.id)
    prompt = @user.conversations.order(:id).last.messages.user.first.content
    assert_match "focus only on direction ##{direction.id}", prompt
  end

  test "a direction added from the sidebar opens on the Hunches tab with its foresight routine" do
    post directions_path, params: { direction: { title: "Payments", brief: "Incidents" } }
    assert_redirected_to hunches_path(direction: Direction.for(@user, @team).last.id)
    assert Foresight.routine_for(@user, @team)
  end

  test "a selected direction shows its outcomes and can be paused or deleted" do
    direction = Direction.create!(user: @user, team: @team, title: "Payments")
    hunch(direction: direction, status: :used)
    get hunches_path(direction: direction.id)
    assert_select ".hdir-meta", text: /1 used · 0 dismissed · 1 hunches/

    patch toggle_direction_path(direction)
    assert direction.reload.paused?
    assert_redirected_to hunches_path(direction: direction.id)

    delete direction_path(direction)
    assert_not Direction.exists?(direction.id)
    assert_redirected_to hunches_path
  end

  test "a blank direction title comes back with an error" do
    post directions_path, params: { direction: { title: " " } }
    assert_redirected_to hunches_path
    assert flash[:alert].present?
  end

  test "the Hunches tab counts what's ready; Sharing and new chat sit in the header" do
    hunch
    hunch(title: "Done", status: :used)
    get hunches_path

    assert_select ".prnav .prnav-item.on .prnav-badge", text: "1"
    assert_select ".prnav .prnav-item", text: /Sharing/, count: 0
    assert_select ".sidebar .ws a.ws-place[href='#{sharing_path}'][aria-label='Sharing']"
    assert_select ".sidebar .ws a[href='#{conversations_path}'][data-turbo-frame='_top']"
  end
end
