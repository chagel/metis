require "test_helper"

class WorkflowBroadcasterTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "wfb-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @run = @team.workflow_runs.create!(conversation: @user.conversations.create!, status: :running)
  end

  test "refresh renders gate/composer/timeline outside a request" do
    @run.tasks.create!(position: 0, gate: :auto, status: :running)
    assert_nothing_raised { WorkflowBroadcaster.new(@run).refresh }
  end

  test "refresh renders the completion summary for a finished run" do
    @run.tasks.create!(position: 0, gate: :auto, status: :completed)
    @run.completed!
    assert_nothing_raised { WorkflowBroadcaster.new(@run).refresh }
  end

  test "a broadcast-rendered avatar src is a path, not a renderer-host URL" do
    @user.avatar.attach(
      io: StringIO.new("\x89PNG\r\n\x1a\nfake".b), filename: "a.png", content_type: "image/png"
    )
    @run.tasks.create!(position: 0, name: "spec", gate: :approval, status: :completed,
                       approved_by: @user, decided_at: Time.current)

    html = ApplicationController.renderer.render(
      partial: "workflow_runs/timeline",
      locals: { run: @run, conversation: @run.conversation }
    )
    assert_no_match "example.org", html
    assert_match %r{src="/}, html
  end

  test "refresh renders the timeline with a decided gate outside a request" do
    message = @run.conversation.messages.create!(
      role: :assistant, content: "the spec", streaming_status: :done,
      started_at: 2.minutes.ago, finished_at: 1.minute.ago,
      model_key: "claude-opus-4-8", input_tokens: 1200, output_tokens: 300, cost: 0.01
    )
    @run.tasks.create!(position: 0, name: "spec", gate: :approval, status: :completed,
                       assistant_message: message, approved_by: @user, decided_at: Time.current)
    assert_nothing_raised { WorkflowBroadcaster.new(@run).refresh }
  end

  test "append_turn renders the injected prompt and pending assistant rows" do
    user = @run.conversation.messages.create!(
      role: :user, content: "implement the spec", streaming_status: :done, kind: :step_prompt
    )
    assistant = @run.conversation.messages.create!(
      role: :assistant, content: "", streaming_status: :pending, started_at: Time.current
    )
    assert_nothing_raised { WorkflowBroadcaster.new(@run).append_turn(user, assistant) }
  end
end
