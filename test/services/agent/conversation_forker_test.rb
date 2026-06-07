require "test_helper"

class Agent::ConversationForkerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "forker@example.com", password: "password123")
    @source = @user.conversations.create!(
      title: "Source",
      settings: { "provider" => "anthropic", "model" => "claude" },
      runtime_state: { "runtime" => "local" },
      backend_session_id: "sess-1"
    )
    @u1 = @source.messages.create!(role: :user, content: "first question", streaming_status: :done)
    @a1 = @source.messages.create!(role: :assistant, content: "first answer", streaming_status: :done)
    @u2 = @source.messages.create!(role: :user, content: "second question", streaming_status: :done)
    @a2 = @source.messages.create!(role: :assistant, content: "second answer", streaming_status: :done)
  end

  test "forking from an assistant message copies the conversation through that turn" do
    fork = Agent::ConversationForker.new(@a1, by: @user).call

    assert_equal [ "first question", "first answer" ], fork.messages.chronological.pluck(:content)
    assert_equal @source.team, fork.team
    assert_equal @source.settings, fork.settings
    assert_equal "Source", fork.title
    assert_equal @a1, fork.forked_from_message
    assert fork.messages.all?(&:done?)
  end

  test "a host-backed source marks the fork pending a real session copy" do
    fork = Agent::ConversationForker.new(@a2, by: @user).call
    assert fork.fork_pending?
    refute fork.needs_history_replay?
  end

  test "a cloud source leaves the fork to replay history" do
    @source.update!(runtime_state: { "runtime" => "e2b" })
    fork = Agent::ConversationForker.new(@a2, by: @user).call

    refute fork.fork_pending?
    assert fork.needs_history_replay?
  end

  test "copied turns carry no usage so the fork accounts its own" do
    @a1.update!(input_tokens: 10, output_tokens: 5, cost: 0.01)
    fork = Agent::ConversationForker.new(@a2, by: @user).call

    assert fork.messages.where.not(input_tokens: nil).none?
    assert fork.messages.where.not(cost: nil).none?
  end
end
