require "test_helper"

# The engine's delegated-step path (docs/local-bridge.md): a step marked
# run:local is dispatched to a device and parked, then settled by a result
# report rather than a cloud turn.
class WorkflowAdvanceDelegationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "wfd-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @device = @team.devices.create!(user: @user, name: "macbook")
  end

  def start(steps)
    WorkflowRun.start(team: @team, user: @user, steps: steps)
  end

  def advance(run)
    WorkflowAdvanceJob.perform_now(run.id)
    run.reload
  end

  LOCAL = { "name" => "impl", "prompt" => "implement the thing", "run" => "local" }.freeze

  test "a delegated step dispatches and parks the run, with no turn" do
    run = start([ LOCAL ])
    assert_no_difference -> { Message.count } do
      advance(run)
    end
    task = run.tasks.first
    assert run.awaiting_local?
    assert task.running?
    assert task.delegated?
    assert task.dispatched_at.present?
    assert_nil task.claimed_by_device
    assert_nil task.assistant_message
  end

  test "a stray advance while awaiting_local does not fail the run" do
    run = start([ LOCAL ])
    advance(run)   # dispatch
    advance(run)   # settle sees a delegated running task → :wait
    assert run.awaiting_local?
    assert run.tasks.first.running?
  end

  test "claim_next_for hands the dispatched task to a device exactly once" do
    run = start([ LOCAL ])
    advance(run)
    other = @team.devices.create!(user: @user, name: "other")

    claimed = Task.claim_next_for(@device)
    assert_equal run.tasks.first, claimed
    assert_equal @device, claimed.reload.claimed_by_device
    assert_nil Task.claim_next_for(other), "an already-claimed task is not handed out twice"
  end

  test "claim_next_for is team-scoped" do
    run = start([ LOCAL ])
    advance(run)
    stranger = User.create!(email: "x-#{SecureRandom.hex(4)}@example.com", password: "password123")
    foreign = stranger.personal_team.devices.create!(user: stranger, name: "theirs")
    assert_nil Task.claim_next_for(foreign)
  end

  test "an auto delegated step completes on result and advances to the next step" do
    run = start([ LOCAL, { "name" => "after", "prompt" => "next", "gate" => "auto" } ])
    advance(run)                                  # dispatch step 0
    task = Task.claim_next_for(@device)

    run.complete_delegated_task!(task, result: { "status" => "completed", "summary" => "did it" }, by_device: @device)
    run.reload
    assert run.running?
    assert run.tasks.find_by(position: 0).completed?
    assert_equal "did it", run.tasks.find_by(position: 0).result["summary"]

    advance(run)                                  # start the cloud step 1
    assert run.tasks.find_by(position: 1).running?
  end

  test "a failed result fails the run" do
    run = start([ LOCAL ])
    advance(run)
    task = Task.claim_next_for(@device)
    run.complete_delegated_task!(task, result: { "status" => "failed", "summary" => "broke" })
    run.reload
    assert run.failed?
    assert run.tasks.first.failed?
  end

  test "an approval-gated delegated step pauses for review after the report" do
    run = start([ LOCAL.merge("gate" => "approval") ])
    advance(run)
    task = Task.claim_next_for(@device)
    run.complete_delegated_task!(task, result: { "status" => "completed", "summary" => "PR #1" })
    run.reload
    assert run.awaiting_approval?
    assert run.tasks.first.awaiting_approval?
  end
end
