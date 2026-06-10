require "test_helper"

# Drives the engine with perform_now and simulates each turn settling by
# stamping the step's assistant message. The :test queue adapter keeps the
# ChatJob that start_step enqueues from actually running pi.
class WorkflowAdvanceJobTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "wfa-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
  end

  def start(steps)
    WorkflowRun.start(team: @team, user: @user, steps: steps)
  end

  def advance(run)
    WorkflowAdvanceJob.perform_now(run.id)
    run.reload
  end

  def finish_turn(run, position, status: :done)
    run.tasks.find_by!(position: position).assistant_message.update!(streaming_status: status)
  end

  AUTO = "auto"
  GATE = "approval"

  test "an auto-only workflow runs through every step and completes" do
    run = start([
      { "name" => "a", "prompt" => "do a", "gate" => AUTO },
      { "name" => "b", "prompt" => "do b", "gate" => AUTO }
    ])

    advance(run)                                   # start step 0
    assert run.running?
    assert run.tasks.find_by(position: 0).running?

    finish_turn(run, 0)
    advance(run)                                   # settle 0, start 1
    assert run.tasks.find_by(position: 0).completed?
    assert run.tasks.find_by(position: 1).running?

    finish_turn(run, 1)
    advance(run)                                   # settle 1, no next → done
    assert run.completed?
    assert run.tasks.find_by(position: 1).completed?
  end

  test "an approval step runs its prompt as a turn, then pauses for review" do
    run = start([ { "name" => "spec", "prompt" => "write the spec", "gate" => GATE } ])

    advance(run)                                   # starts the spec turn
    spec = run.tasks.find_by(position: 0)
    assert spec.running?, "the gated step should run its turn first, not pause immediately"
    assert run.running?
    assert_equal 1, run.conversation.messages.assistant.count

    finish_turn(run, 0)
    advance(run)                                   # turn done + approval → gate now
    assert run.awaiting_approval?
    assert spec.reload.awaiting_approval?
  end

  test "a prompt-less approval step is a pure checkpoint — pauses with no turn" do
    run = start([ { "name" => "sign-off", "gate" => GATE } ])
    advance(run)
    assert run.awaiting_approval?
    assert_equal 0, run.conversation.messages.count
  end

  test "a prompt-less auto step is skipped" do
    run = start([
      { "name" => "noop", "gate" => AUTO },
      { "name" => "real", "prompt" => "do it", "gate" => AUTO }
    ])
    advance(run)
    assert run.tasks.find_by(position: 0).skipped?
    assert run.tasks.find_by(position: 1).running?
  end

  test "an approval gate pauses the run; approving resumes it" do
    run = start([
      { "name" => "spec", "prompt" => "write spec", "gate" => AUTO },
      { "name" => "review", "gate" => GATE },
      { "name" => "ship", "prompt" => "ship it", "gate" => AUTO }
    ])

    advance(run)
    finish_turn(run, 0)
    advance(run)                                   # settle 0, hit gate
    assert run.awaiting_approval?
    assert run.tasks.find_by(position: 1).awaiting_approval?

    run.approve_current_gate!(by: @user)
    gate_task = run.tasks.find_by(position: 1)
    assert gate_task.reload.completed?
    assert_equal @user, gate_task.approved_by
    assert run.reload.running?

    advance(run)                                   # start step 2
    assert run.tasks.find_by(position: 2).running?
    finish_turn(run, 2)
    advance(run)
    assert run.completed?
  end

  test "request changes re-runs the step with feedback, then gates again" do
    user = @user
    run = start([ { "name" => "spec", "prompt" => "write the spec", "gate" => GATE } ])
    advance(run)
    finish_turn(run, 0)
    advance(run)
    assert run.awaiting_approval?

    run.request_changes!("actually, open a PR too", by: user)
    spec = run.tasks.find_by(position: 0)
    assert spec.reload.running?, "the step re-runs rather than cancelling"
    assert run.reload.running?
    feedback = run.conversation.messages.user.order(:created_at).last
    assert feedback.review?, "the feedback is a review record in the timeline"
    assert_includes feedback.content, "requested changes — actually, open a PR too"

    finish_turn(run, 0)
    advance(run)
    assert run.awaiting_approval?, "the revised step gates again for re-review"
  end

  test "request changes with blank feedback is a no-op" do
    run = start([ { "name" => "spec", "prompt" => "write the spec", "gate" => GATE } ])
    advance(run)
    finish_turn(run, 0)
    advance(run)
    run.request_changes!("  ", by: @user)
    assert run.awaiting_approval?
  end

  test "rejecting a gate cancels the run" do
    run = start([
      { "name" => "spec", "prompt" => "write spec", "gate" => AUTO },
      { "name" => "review", "gate" => GATE }
    ])
    advance(run)
    finish_turn(run, 0)
    advance(run)
    assert run.awaiting_approval?

    run.reject_current_gate!(by: @user)
    assert run.reload.cancelled?
    assert run.tasks.find_by(position: 1).rejected?
  end

  test "an errored turn fails the run and the step" do
    run = start([ { "name" => "a", "prompt" => "do a", "gate" => AUTO } ])
    advance(run)
    finish_turn(run, 0, status: :errored)
    advance(run)
    assert run.failed?
    assert run.tasks.find_by(position: 0).failed?
  end

  test "a canceled turn fails the run" do
    run = start([ { "name" => "a", "prompt" => "do a", "gate" => AUTO } ])
    advance(run)
    finish_turn(run, 0, status: :canceled)
    advance(run)
    assert run.failed?
  end

  test "advancing while a turn is still in flight waits — no second turn" do
    run = start([
      { "name" => "a", "prompt" => "do a", "gate" => AUTO },
      { "name" => "b", "prompt" => "do b", "gate" => AUTO }
    ])
    advance(run)                                   # start step 0 (message pending)
    assert_no_difference -> { run.conversation.messages.count } do
      advance(run)                                 # message still pending → wait
    end
    assert run.tasks.find_by(position: 0).running?
    assert run.tasks.find_by(position: 1).pending?
  end

  test "an empty workflow completes immediately" do
    run = start([])
    advance(run)
    assert run.completed?
  end

  test "a finished, inactive run ignores further advances" do
    run = start([ { "name" => "a", "prompt" => "do a", "gate" => AUTO } ])
    advance(run)
    finish_turn(run, 0)
    advance(run)
    assert run.completed?

    assert_nothing_raised { advance(run) }
    assert run.completed?
  end
end
