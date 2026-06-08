require "test_helper"

class ConversationTurnTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "ct-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @conversation = @user.conversations.create!
  end

  test "creates the user + pending assistant pair and enqueues ChatJob" do
    user_message = assistant_message = nil
    assert_enqueued_with(job: ChatJob) do
      user_message, assistant_message = ConversationTurn.start(@conversation, content: "hello")
    end

    assert user_message.user?
    assert_equal "hello", user_message.content
    assert user_message.done?

    assert assistant_message.assistant?
    assert assistant_message.pending?
    assert_not_nil assistant_message.started_at
  end

  test "yields the user message before the assistant row exists" do
    seen_assistant_count = nil
    ConversationTurn.start(@conversation, content: "hi") do |user_message|
      assert user_message.persisted?
      seen_assistant_count = @conversation.messages.assistant.count
    end
    assert_equal 0, seen_assistant_count
  end
end
