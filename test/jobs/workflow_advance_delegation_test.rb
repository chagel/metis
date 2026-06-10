require "test_helper"

# The engine's delegated-step path (docs/local-bridge.md): a step marked
# run:local is dispatched to the user's machine and parked, then settled by
# a result report rather than a cloud turn.
class WorkflowAdvanceDelegationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "wfd-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
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
    assert_nil task.claimed_by
    assert_nil task.assistant_message
  end

  test "a stray advance while awaiting_local does not fail the run" do
    run = start([ LOCAL ])
    advance(run)   # dispatch
    advance(run)   # settle sees a delegated running task → :wait
    assert run.awaiting_local?
    assert run.tasks.first.running?
  end

  test "claim_next_for hands the dispatched task out exactly once" do
    run = start([ LOCAL ])
    advance(run)

    claimed = Task.claim_next_for(@user, client: "macbook")
    assert_equal run.tasks.first, claimed
    assert_equal "macbook", claimed.reload.claimed_by
    assert_nil Task.claim_next_for(@user), "an already-claimed task is not handed out twice"
  end

  test "claim_next_for is scoped to the user's teams" do
    run = start([ LOCAL ])
    advance(run)
    stranger = User.create!(email: "x-#{SecureRandom.hex(4)}@example.com", password: "password123")
    assert_nil Task.claim_next_for(stranger)
  end

  test "an auto delegated step completes on result and advances to the next step" do
    run = start([ LOCAL, { "name" => "after", "prompt" => "next", "gate" => "auto" } ])
    advance(run)                                  # dispatch step 0
    task = Task.claim_next_for(@user, client: "macbook")

    run.complete_delegated_task!(task, result: {
      "status" => "completed", "summary" => "did it",
      "artifacts" => [ { "type" => "pr", "url" => "http://x/1" } ]
    })
    run.reload
    assert run.running?
    assert run.tasks.find_by(position: 0).completed?
    assert_equal "did it", run.tasks.find_by(position: 0).result["summary"]

    report = run.conversation.messages.where(role: :assistant, workflow_generated: true).last
    assert_equal "Done on macbook — did it → http://x/1", report.content
    assert report.done?

    advance(run)                                  # start the cloud step 1
    next_task = run.tasks.find_by(position: 1)
    assert next_task.running?

    # The local result never entered the agent session, so the next cloud
    # prompt must carry it.
    step_prompt = run.conversation.messages.where(role: :user, workflow_generated: true).last.content
    assert_includes step_prompt, %(Step "impl" ran on the user's machine and reported: did it (http://x/1))
    assert_includes step_prompt, "next"
  end

  test "a failed result fails the run and leaves a failure report line" do
    run = start([ LOCAL ])
    advance(run)
    task = Task.claim_next_for(@user)
    run.complete_delegated_task!(task, result: { "status" => "failed", "summary" => "broke" })
    run.reload
    assert run.failed?
    assert run.tasks.first.failed?
    report = run.conversation.messages.where(role: :assistant, workflow_generated: true).last
    assert_equal "Failed on local agent — broke", report.content
  end

  test "an approval-gated delegated step pauses for review after the report" do
    run = start([ LOCAL.merge("gate" => "approval") ])
    advance(run)
    task = Task.claim_next_for(@user)
    run.complete_delegated_task!(task, result: { "status" => "completed", "summary" => "PR #1" })
    run.reload
    assert run.awaiting_approval?
    assert run.tasks.first.awaiting_approval?
  end
end
