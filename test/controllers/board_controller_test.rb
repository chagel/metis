require "test_helper"

class BoardControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "board-ctrl@example.com", password: "password123")
    @team = @user.personal_team
    @project = @team.projects.create!(name: "Cheese")
  end

  def new_run(status: :running)
    conversation = @user.conversations.create!(team: @team, project: @project)
    @team.workflow_runs.create!(conversation: conversation, status: status)
  end

  test "redirects to sign in when not authenticated" do
    get board_path
    assert_redirected_to new_user_session_path
  end

  test "renders the board inside the chat shell with the primary nav" do
    sign_in @user
    get board_path
    assert_response :success
    assert_select ".sidebar .prnav .prnav-item.on", text: /Board/
  end

  test "places a run in its status column and project lane" do
    run = new_run(status: :awaiting_approval)
    run.tasks.create!(position: 0, name: "review", gate: :approval, status: :awaiting_approval)

    sign_in @user
    get board_path
    assert_response :success
    assert_select ".board-lane .board-proj", text: "Cheese"
    assert_select "##{ActionView::RecordIdentifier.dom_id(run, :board)}"
  end

  test "shows the badge count of runs needing the user" do
    new_run(status: :awaiting_local)
    sign_in @user
    get board_path
    assert_select ".prnav-badge", text: "1"
  end

  test "shows the empty state when the team has no runs" do
    sign_in @user
    get board_path
    assert_select ".board-empty"
  end

  test "renders the actors bar with a focusable toggle and people in the panel" do
    sign_in @user
    get board_path
    assert_select "#board_actors button.board-actors-bar[aria-expanded]"
    assert_select "#board_actors_panel .board-arow .board-arow-nm", text: /board-ctrl@example.com/
    assert_select "#board_actors_panel .board-actors-empty"
  end

  test "renders a connected machine with the online over total summary" do
    @user.generate_bridge_token!
    @user.update_columns(bridge_seen_at: 10.seconds.ago, bridge_client: "Apollo")
    sign_in @user
    get board_path
    assert_select "#board_actors .board-actors-ct", text: "1/1"
    assert_select "#board_actors_panel .board-arow-nm.board-mono", text: /Apollo/
    assert_select "#board_actors_panel .board-lite", text: /online/
  end
end
