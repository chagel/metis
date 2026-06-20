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
    project = @team.projects.find_or_create_by!(name: "Engine")
    WorkflowRun.start(team: @team, user: @user, project: project, steps: steps)
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

  test "a later step's prompt restates the run input under an orientation header" do
    run = WorkflowRun.start(team: @team, user: @user, input: "review pr 75",
                            project: @team.projects.find_or_create_by!(name: "Engine"), steps: [
      { "name" => "a", "prompt" => "do a", "gate" => AUTO },
      { "name" => "b", "prompt" => "do b", "gate" => AUTO }
    ])
    advance(run)
    finish_turn(run, 0)
    advance(run)

    prompts = run.conversation.messages.where(kind: :step_prompt).order(:created_at).map(&:content)
    assert_equal [ <<~STEP0.strip, <<~STEP1.strip ], prompts
      **Multi-step run · step 1 of 2 — "a"**

      Steps in this run:
      1. a — current step
      2. b — pending

      review pr 75

      do a
    STEP0
      **Multi-step run · step 2 of 2 — "b"**

      Steps in this run:
      1. a — done
      2. b — current step

      review pr 75

      do b
    STEP1
  end

  test "a named workflow's header names the workflow" do
    workflow = @team.workflows.create!(name: "ship", steps: [])
    run = WorkflowRun.start(team: @team, user: @user, workflow: workflow,
                            project: @team.projects.find_or_create_by!(name: "Engine"), steps: [
      { "name" => "Build", "prompt" => "do a", "gate" => AUTO },
      { "name" => "Ship", "prompt" => "do b", "gate" => AUTO }
    ])
    advance(run)
    header = run.conversation.messages.where(kind: :step_prompt).first.content
    assert_match %r{\A\*\*Workflow: ship · step 1 of 2 — "Build"\*\*}, header
  end

  test "a single-step run gets no orientation header" do
    run = start([ { "name" => "only", "prompt" => "do it", "gate" => AUTO } ])
    advance(run)
    assert_equal "do it", run.conversation.messages.where(kind: :step_prompt).first.content
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
    header = run.conversation.messages.where(kind: :step_prompt).first.content
    assert_includes header, "1. noop — skipped"
    assert_includes header, "2. real — current step"
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
    assert_equal user, feedback.sender, "gate feedback is attributed to the reviewer"

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
