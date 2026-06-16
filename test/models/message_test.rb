require "test_helper"

class MessageTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    user = User.create!(email: "msg-model@example.com", password: "password123")
    @conversation = user.conversations.create!
  end

  test "attachments? is false for a message with no uploads" do
    message = @conversation.messages.create!(role: :user, content: "hi", streaming_status: :done)
    assert_not message.attachments?
  end

  test "attachments? is true once an image or file is attached" do
    message = @conversation.messages.create!(role: :user, content: "hi", streaming_status: :done)
    message.files.attach(io: StringIO.new("data"), filename: "notes.txt", content_type: "text/plain")
    assert message.attachments?
  end

  test "duration is nil until the turn has both timestamps" do
    message = @conversation.messages.create!(role: :assistant, content: "", streaming_status: :pending)
    assert_nil message.duration

    message.update!(started_at: Time.current)
    assert_nil message.duration
  end

  test "duration is the seconds between started_at and finished_at" do
    start = Time.current
    message = @conversation.messages.create!(
      role: :assistant, content: "hi", streaming_status: :done,
      started_at: start, finished_at: start + 4.2.seconds
    )
    assert_in_delta 4.2, message.duration, 0.001
  end

  test "enqueues title generation as soon as the user's chat message lands" do
    assert_enqueued_with(job: GenerateConversationTitleJob, args: [ @conversation.id ]) do
      @conversation.messages.create!(role: :user, content: "hi", streaming_status: :done)
    end
  end

  test "does not enqueue title generation when the title already exists" do
    @conversation.update!(title: "Already named")

    assert_no_enqueued_jobs only: GenerateConversationTitleJob do
      @conversation.messages.create!(role: :user, content: "hi", streaming_status: :done)
    end
  end

  test "does not enqueue on a workflow-marker user message" do
    assert_no_enqueued_jobs only: GenerateConversationTitleJob do
      @conversation.messages.create!(role: :user, content: "step 1", streaming_status: :done, kind: :step_prompt)
    end
  end

  test "does not enqueue on assistant-message create" do
    assert_no_enqueued_jobs only: GenerateConversationTitleJob do
      @conversation.messages.create!(role: :assistant, content: "", streaming_status: :pending)
    end
  end
end
