require "test_helper"

class WorkflowBroadcasterTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "wfb-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @run = @team.workflow_runs.create!(conversation: @user.conversations.create!, status: :running)
  end

  test "refresh renders rail/gate/composer outside a request" do
    @run.tasks.create!(position: 0, gate: :auto, status: :running)
    assert_nothing_raised { WorkflowBroadcaster.new(@run).refresh }
  end

  test "refresh renders the completion summary for a finished run" do
    @run.tasks.create!(position: 0, gate: :auto, status: :completed)
    @run.completed!
    assert_nothing_raised { WorkflowBroadcaster.new(@run).refresh }
  end

  test "append_turn renders the injected prompt and pending assistant rows" do
    user = @run.conversation.messages.create!(
      role: :user, content: "implement the spec", streaming_status: :done, workflow_generated: true
    )
    assistant = @run.conversation.messages.create!(
      role: :assistant, content: "", streaming_status: :pending, started_at: Time.current
    )
    assert_nothing_raised { WorkflowBroadcaster.new(@run).append_turn(user, assistant) }
  end
end
