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
    # nav-tabs keeps the active tab in sync when a conversation opens in #main.
    assert_select ".sidebar .prnav[data-controller='nav-tabs']"
    assert_select ".sidebar .prnav .prnav-item[data-nav-tabs-target='link']", count: 3
  end

  test "the board opens collapsed by default, with rail destinations" do
    sign_in @user
    get board_path
    assert_response :success
    assert_select ".app.sidebar-collapsed"
    assert_select ".sidebar-rail a.rail-dest", minimum: 4
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

  test "renders the status bar with focusable toggles and people in the panel" do
    sign_in @user
    get board_path
    assert_select "#board_actors button.board-side-bar[aria-expanded]", count: 2
    assert_select "#board_people_panel .board-arow .board-arow-nm", text: /board-ctrl@example.com/
    assert_select "#board_machines_panel .board-actors-empty"
  end

  test "renders a connected machine with the online over total summary" do
    @user.generate_bridge_token!
    @user.update_columns(bridge_seen_at: 10.seconds.ago, bridge_client: "Apollo")
    sign_in @user
    get board_path
    assert_select "#board_actors .board-actors-ct", text: "1/1"
    assert_select "#board_machines_panel .board-arow-nm.board-mono", text: /Apollo/
    assert_select "#board_machines_panel .board-lite .board-dot--live"
    assert_select "#board_machines_panel .board-lite", text: /seen 10s/
  end

  test "actors action returns a turbo stream replacing the bar" do
    sign_in @user
    get board_actors_path
    assert_response :success
    assert_match "text/vnd.turbo-stream", response.media_type
    assert_select "turbo-stream[action=replace][target=board_actors]"
  end

  test "the actors poll url carries the active filters" do
    sign_in @user
    get board_path(scope: "mine", projects: [ @project.id ])
    assert_select "#board_actors[data-poll-url-value*='scope=mine']"
    assert_select "#board_actors[data-poll-url-value*='projects']"
  end

  test "scope=mine hides a teammate's team run" do
    teammate = User.create!(email: "mate@example.com", password: "password123")
    @team.memberships.create!(user: teammate, role: :member)
    mine = new_run(status: :running)
    theirs_conv = teammate.conversations.create!(team: @team, project: @project, visibility: :team)
    theirs = @team.workflow_runs.create!(conversation: theirs_conv, status: :running)

    sign_in @user
    get board_path(scope: "mine")
    assert_select "##{ActionView::RecordIdentifier.dom_id(mine, :board)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(theirs, :board)}", count: 0
  end

  test "projects checklist filters to the selected projects" do
    other = @team.projects.create!(name: "Atlas")
    excluded = @team.projects.create!(name: "Brie")
    here = new_run(status: :running)
    there = @team.workflow_runs.create!(
      conversation: @user.conversations.create!(team: @team, project: other), status: :running
    )
    gone = @team.workflow_runs.create!(
      conversation: @user.conversations.create!(team: @team, project: excluded), status: :running
    )

    sign_in @user
    get board_path(projects: [ @project.id, other.id ])
    assert_select "##{ActionView::RecordIdentifier.dom_id(here, :board)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(there, :board)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(gone, :board)}", count: 0
    assert_select ".board-projfilter .board-chip", text: /2 projects/
  end

  test "the projects checklist renders a checkbox per team project" do
    @team.projects.create!(name: "Atlas")
    sign_in @user
    get board_path
    assert_select ".board-projfilter-panel input[type=checkbox][name='projects[]']", count: 2
  end

  test "done=24h hides an old terminal run that done=all reveals" do
    old = new_run(status: :completed)
    old.update_columns(updated_at: 3.days.ago)
    sel = "##{ActionView::RecordIdentifier.dom_id(old, :board)}"

    sign_in @user
    get board_path(done: "24h")
    assert_select sel, count: 0
    get board_path(done: "all")
    assert_select sel
  end

  test "done=2w reveals a terminal run older than the 7d window" do
    old = new_run(status: :completed)
    old.update_columns(updated_at: 10.days.ago)
    sel = "##{ActionView::RecordIdentifier.dom_id(old, :board)}"

    sign_in @user
    get board_path(done: "7d")
    assert_select sel, count: 0
    get board_path(done: "2w")
    assert_select sel
  end

  test "the done-window toggle offers every configured window" do
    sign_in @user
    get board_path
    assert_select ".board-done .board-done-opt", count: Board::DONE_WINDOWS.size
    assert_select ".board-done .board-done-opt", text: "2w"
    assert_select ".board-done .board-done-opt", text: "1m"
  end

  test "an unknown scope falls back to all" do
    run = new_run(status: :running)
    sign_in @user
    get board_path(scope: "bogus")
    assert_response :success
    assert_select ".board-chip.is-on", count: 0
    assert_select ".board-projfilter .board-chip--drop", text: /All projects/
    assert_select "##{ActionView::RecordIdentifier.dom_id(run, :board)}"
  end
end
