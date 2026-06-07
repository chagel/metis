require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "msg@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Chat")
    sign_in @user
  end

  test "creates a user message and assistant placeholder, enqueues ChatJob" do
    assert_difference -> { @conversation.messages.count }, 2 do
      assert_enqueued_with(job: ChatJob) do
        post conversation_messages_path(@conversation),
             params: { content: "Hello agent" }, as: :turbo_stream
      end
    end

    assert_response :success
    assert_equal "Hello agent", @conversation.messages.find_by(role: :user)&.content
    assert @conversation.messages.exists?(role: :assistant, streaming_status: :pending)
  end

  test "the create stream renders no fork action yet" do
    post conversation_messages_path(@conversation),
         params: { content: "Hello agent" }, as: :turbo_stream

    assert_response :success
    # User messages aren't forkable, and the assistant is still pending — its
    # action is revealed only at turn end (ChatBroadcaster#reveal_fork).
    assert_equal 0, response.body.scan("msg-fork-form").size
  end

  test "replying lifts the conversation to the top of the sidebar list" do
    post conversation_messages_path(@conversation),
         params: { content: "Hello agent" }, as: :turbo_stream

    assert_response :success
    assert_match %r{turbo-stream action="remove" target="conversation_#{@conversation.id}"}, response.body
    assert_match %r{turbo-stream action="remove" target="convos-today-label"}, response.body
    assert_match %r{turbo-stream action="prepend" target="convos-list"}, response.body
  end

  test "stamps started_at on the assistant message when the turn starts" do
    post conversation_messages_path(@conversation),
         params: { content: "Hello agent" }, as: :turbo_stream

    assert_response :success
    assert_not_nil @conversation.messages.find_by(role: :assistant)&.started_at
  end

  test "rejects a blank message with no attachments" do
    assert_no_difference -> { @conversation.messages.count } do
      post conversation_messages_path(@conversation),
           params: { content: "   " }, as: :turbo_stream
    end
    assert_response :unprocessable_entity
  end

  test "attaches an uploaded file to the user message" do
    assert_difference -> { @conversation.messages.count }, 2 do
      assert_enqueued_with(job: ChatJob) do
        post conversation_messages_path(@conversation), params: {
          content: "see attached",
          attachments: [ fixture_file_upload("sample.txt", "text/plain") ]
        }, as: :turbo_stream
      end
    end

    assert_response :success
    user_message = @conversation.messages.find_by(role: :user)
    assert user_message.files.attached?
    assert_equal "sample.txt", user_message.files.first.filename.to_s
  end

  test "accepts an attachment-only message with no text" do
    assert_difference -> { @conversation.messages.count }, 2 do
      post conversation_messages_path(@conversation), params: {
        attachments: [ fixture_file_upload("sample.png", "image/png") ]
      }, as: :turbo_stream
    end

    assert_response :success
    assert @conversation.messages.find_by(role: :user).images.attached?
  end

  test "rejects an unsupported attachment type" do
    assert_no_difference -> { @conversation.messages.count } do
      post conversation_messages_path(@conversation), params: {
        content: "bad upload",
        attachments: [ fixture_file_upload("sample.txt", "application/x-msdownload") ]
      }, as: :turbo_stream
    end
    assert_response :unprocessable_entity
  end

  test "rejects a new message while a turn is already in progress" do
    @conversation.messages.create!(role: :assistant, content: "", streaming_status: :streaming)

    assert_no_difference -> { @conversation.messages.count } do
      post conversation_messages_path(@conversation),
           params: { content: "second" }, as: :turbo_stream
    end
    assert_response :conflict
  end

  test "does not let a user post to another user's conversation" do
    other = User.create!(email: "other-msg@example.com", password: "password123")
    other_conversation = other.conversations.create!

    post conversation_messages_path(other_conversation),
         params: { content: "sneaky" }, as: :turbo_stream
    assert_response :not_found
  end

  test "requires authentication" do
    sign_out @user
    post conversation_messages_path(@conversation),
         params: { content: "hi" }, as: :turbo_stream
    assert_redirected_to new_user_session_path
  end

  test "forking a message creates a new conversation through that turn and redirects" do
    @conversation.messages.create!(role: :user, content: "hi", streaming_status: :done)
    assistant = @conversation.messages.create!(role: :assistant, content: "hello there", streaming_status: :done)

    assert_difference -> { @user.conversations.count }, 1 do
      post fork_conversation_message_path(@conversation, assistant)
    end

    fork = @user.conversations.recent.first
    assert_redirected_to conversation_path(fork)
    assert_equal assistant, fork.forked_from_message
    assert_equal [ "hi", "hello there" ], fork.messages.chronological.pluck(:content)
  end

  test "cannot fork a user message" do
    user_message = @conversation.messages.create!(role: :user, content: "redo this", streaming_status: :done)

    assert_no_difference -> { Conversation.count } do
      post fork_conversation_message_path(@conversation, user_message)
    end
    assert_response :unprocessable_entity
  end

  test "cannot fork a message in another user's conversation" do
    other = User.create!(email: "other-fork@example.com", password: "password123")
    other_conversation = other.conversations.create!
    message = other_conversation.messages.create!(role: :assistant, content: "x", streaming_status: :done)

    assert_no_difference -> { Conversation.count } do
      post fork_conversation_message_path(other_conversation, message)
    end
    assert_response :not_found
  end

  test "cannot fork a streaming message" do
    message = @conversation.messages.create!(role: :assistant, content: "", streaming_status: :streaming)

    assert_no_difference -> { Conversation.count } do
      post fork_conversation_message_path(@conversation, message)
    end
    assert_response :unprocessable_entity
  end
end
