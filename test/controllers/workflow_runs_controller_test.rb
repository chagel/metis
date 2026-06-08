require "test_helper"

class WorkflowRunsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "wfc-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    sign_in @user
  end

  # Build a run already paused at a gate, without driving the engine.
  def gated_run
    conversation = @user.conversations.create!
    run = @team.workflow_runs.create!(conversation: conversation, status: :awaiting_approval)
    msg = conversation.messages.create!(role: :assistant, content: "the spec", streaming_status: :done)
    run.tasks.create!(position: 0, name: "spec", gate: :auto, status: :completed, assistant_message: msg)
    run.tasks.create!(position: 1, name: "review", gate: :approval, status: :awaiting_approval)
    run
  end

  test "approve completes the gate, resumes the run, and enqueues an advance" do
    run = gated_run
    assert_enqueued_with(job: WorkflowAdvanceJob) do
      post approve_workflow_run_path(run), as: :turbo_stream
    end
    assert_response :success
    assert run.reload.running?
    gate = run.tasks.find_by(position: 1)
    assert gate.completed?
    assert_equal @user, gate.approved_by
  end

  test "reject cancels the run" do
    run = gated_run
    post reject_workflow_run_path(run), as: :turbo_stream
    assert_response :success
    assert run.reload.cancelled?
    assert run.tasks.find_by(position: 1).rejected?
  end

  test "a run in another team is not reachable" do
    run = gated_run
    sign_out @user
    sign_in User.create!(email: "wfc-out-#{SecureRandom.hex(4)}@example.com", password: "password123")
    post approve_workflow_run_path(run), as: :turbo_stream
    assert_response :not_found
    assert run.reload.awaiting_approval?
  end

  test "the conversation view renders the rail and the gate card" do
    run = gated_run
    get conversation_path(run.conversation)
    assert_response :success
    assert_select "#workflow_rail"
    assert_select "#workflow_gate"
    assert_match "Review needed", response.body
    assert_match "the spec", response.body
  end
end
