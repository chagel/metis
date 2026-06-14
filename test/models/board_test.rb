require "test_helper"

class BoardTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "board-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @project = @team.projects.create!(name: "Cheese")
  end

  def new_run(status: :running, project: @project, user: @user, visibility: :personal, updated_at: nil)
    conversation = user.conversations.create!(team: @team, project: project, visibility: visibility)
    run = @team.workflow_runs.create!(conversation: conversation, status: status)
    run.update_columns(updated_at: updated_at) if updated_at
    run
  end

  test "groups runs into the four status columns" do
    running  = new_run(status: :running)
    approval = new_run(status: :awaiting_approval)
    local    = new_run(status: :awaiting_local)
    done     = new_run(status: :completed)

    columns = Board.for(team: @team, user: @user).lanes.first.columns

    assert_equal [ running ], columns[:running]
    assert_equal [ approval ], columns[:awaiting_approval]
    assert_equal [ local ], columns[:awaiting_local]
    assert_equal [ done ], columns[:done]
  end

  test "pending folds into running and terminal states fold into done" do
    pending   = new_run(status: :pending)
    failed    = new_run(status: :failed)
    cancelled = new_run(status: :cancelled)

    columns = Board.for(team: @team, user: @user).lanes.first.columns

    assert_includes columns[:running], pending
    assert_includes columns[:done], failed
    assert_includes columns[:done], cancelled
  end

  test "one lane per project, ordered by most recent run" do
    other = @team.projects.create!(name: "Atlas")
    new_run(project: @project, updated_at: 2.hours.ago)
    new_run(project: other, updated_at: 1.minute.ago)

    lanes = Board.for(team: @team, user: @user).lanes
    assert_equal [ "Atlas", "Cheese" ], lanes.map { |lane| lane.project.name }
  end

  test "runs without a project land in a synthetic lane sorted last" do
    new_run(project: @project)
    orphan = new_run(project: nil)

    lanes = Board.for(team: @team, user: @user).lanes
    assert_nil lanes.last.project
    assert_includes lanes.last.columns.values.flatten, orphan
  end

  test "terminal runs older than the window are excluded but active ones never are" do
    fresh_done = new_run(status: :completed, updated_at: 1.hour.ago)
    new_run(status: :completed, updated_at: 2.days.ago)
    old_active = new_run(status: :awaiting_local, updated_at: 5.days.ago)

    runs = Board.for(team: @team, user: @user).lanes.flat_map { |lane| lane.columns.values }.flatten
    assert_includes runs, fresh_done
    assert_includes runs, old_active
    assert_equal 2, runs.size
  end

  test "a teammate's personal run is hidden, a team run is shown" do
    teammate = User.create!(email: "mate-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team.memberships.create!(user: teammate, role: :member)

    personal = new_run(user: teammate, visibility: :personal)
    shared   = new_run(user: teammate, visibility: :team)

    runs = Board.for(team: @team, user: @user).lanes.flat_map { |lane| lane.columns.values }.flatten
    refute_includes runs, personal
    assert_includes runs, shared
  end

  test "needs_you_count counts awaiting runs only" do
    new_run(status: :running)
    new_run(status: :awaiting_approval)
    new_run(status: :awaiting_local)

    assert_equal 2, Board.for(team: @team, user: @user).needs_you_count
  end

  test "empty board reports none" do
    refute Board.for(team: @team, user: @user).any?
  end
end
