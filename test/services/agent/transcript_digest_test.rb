require "test_helper"

class Agent::TranscriptDigestTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "td-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @conversation = @user.conversations.create!
    @conversation.messages.create!(role: :user, content: "hello", streaming_status: :done)
    @conversation.messages.create!(role: :assistant, content: "hi there", streaming_status: :done)
    # The in-flight turn's user message — replayable_history excludes it.
    @conversation.messages.create!(role: :user, content: "trigger", streaming_status: :done)
  end

  test "quotes prior turns, excluding the in-flight turn" do
    out = Agent::TranscriptDigest.new(@conversation).to_s

    assert_includes out, "**Operator:**"
    assert_includes out, "> hello"
    assert_includes out, "**Agent:**"
    assert_includes out, "> hi there"
    refute_includes out, "trigger"
  end

  test "agent_label addresses the agent in first person for Identity replay" do
    out = Agent::TranscriptDigest.new(@conversation, agent_label: "You").to_s
    assert_includes out, "**You:**"
    refute_includes out, "**Agent:**"
  end

  test "marks how many older messages were dropped past the budget" do
    out = Agent::TranscriptDigest.new(@conversation, char_budget: 1).to_s
    assert_match(/earlier message.*omitted/, out)
  end
end
