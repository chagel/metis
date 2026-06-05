require "test_helper"

class DaytonaStopJobTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "dsj-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @conversation = @user.conversations.create!(daytona_sandbox_id: "sbx-1")
    # The assistant message of the turn that scheduled the stop.
    @message = @conversation.messages.create!(role: :assistant, content: "hi", streaming_status: :done)
    @stops = []
  end

  # Runs the job with the network-hitting stop_sandbox swapped for a recorder.
  def run_job(sandbox_id: "sbx-1", token: @message.id)
    stops = @stops
    klass = Agent::Runtime::Daytona
    original = klass.method(:stop_sandbox)
    klass.define_singleton_method(:stop_sandbox) { |conv, id| stops << [ conv.id, id ] }
    DaytonaStopJob.perform_now(@conversation.id, sandbox_id, token)
  ensure
    klass.define_singleton_method(:stop_sandbox, original)
  end

  test "stops the sandbox when idle, matching, and unchanged" do
    run_job
    assert_equal [ [ @conversation.id, "sbx-1" ] ], @stops
  end

  test "no-ops when the conversation's sandbox id has changed" do
    @conversation.update_column(:daytona_sandbox_id, "sbx-2")
    run_job(sandbox_id: "sbx-1")
    assert_empty @stops
  end

  test "no-ops while a turn is in progress" do
    @conversation.messages.create!(role: :assistant, content: "", streaming_status: :streaming)
    run_job # stale token; turn_in_progress? guards first
    assert_empty @stops
  end

  test "no-ops when a newer turn has used the box since the stop was scheduled" do
    @conversation.messages.create!(role: :user, content: "again", streaming_status: :done)
    run_job(token: @message.id) # token predates the new message
    assert_empty @stops
  end

  test "no-ops when the conversation no longer exists" do
    @conversation.update_column(:daytona_sandbox_id, nil) # avoid the destroy hook's API call
    id = @conversation.id
    @conversation.destroy
    run_job_for(id)
    assert_empty @stops
  end

  def run_job_for(conversation_id)
    stops = @stops
    klass = Agent::Runtime::Daytona
    original = klass.method(:stop_sandbox)
    klass.define_singleton_method(:stop_sandbox) { |_conv, _id| stops << :called }
    DaytonaStopJob.perform_now(conversation_id, "sbx-1", 999)
  ensure
    klass.define_singleton_method(:stop_sandbox, original)
  end
end
