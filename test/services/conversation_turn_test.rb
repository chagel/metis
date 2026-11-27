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

  test "shows the new turn and the Stop button in every window on the conversation" do
    streams = capture_turbo_stream_broadcasts(@conversation) do
      @user_message, @assistant_message = ConversationTurn.start(@conversation, content: "hello")
    end

    assert_equal %w[messages messages composer_actions], streams.map { it["target"] }
    assert_includes streams[0].to_html, ActionView::RecordIdentifier.dom_id(@user_message)
    assert_includes streams[1].to_html, ActionView::RecordIdentifier.dom_id(@assistant_message)
    assert_includes streams[2].to_html, 'data-composer-state="streaming"'
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
