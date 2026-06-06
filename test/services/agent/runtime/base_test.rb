require "test_helper"

class Agent::Runtime::BaseTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rtbase@example.com", password: "password123")
    @conversation = @user.conversations.create!
    @runtime = Agent::Runtime::Base.new(conversation: @conversation)
  end

  test "emit_status forwards the phase and message to the status sink" do
    calls = []
    @runtime.status_sink = ->(phase, message) { calls << [ phase, message ] }

    @runtime.emit_status(:creating, "Creating sandbox")

    assert_equal [ [ :creating, "Creating sandbox" ] ], calls
  end

  test "emit_status is a silent no-op without a status sink" do
    assert_nothing_raised { @runtime.emit_status(:resuming, "Resuming sandbox") }
  end

  test "emit_status swallows a failing sink so a broadcast can't crash the turn" do
    @runtime.status_sink = ->(_phase, _message) { raise "broadcast down" }

    assert_nothing_raised { @runtime.emit_status(:starting, "Starting container") }
  end

  test "initial_status is nil for the base (no provisioning to predict)" do
    assert_nil @runtime.initial_status
  end

  test "identity_content restores history only on a fresh sandbox that lost a prior session" do
    @conversation.update!(backend_session_id: "sess-123")
    @conversation.messages.create!(role: :user, content: "earlier ask", streaming_status: :done)
    @conversation.messages.create!(role: :assistant, content: "earlier reply", streaming_status: :done)
    @conversation.messages.create!(role: :user, content: "current", streaming_status: :done)

    # A reaped sandbox: provisioned fresh (@sandbox_was_resumed = false) for a
    # conversation that already had a pi session (backend_session_id present).
    @runtime.instance_variable_set(:@sandbox_was_resumed, false)
    assert_match(/## Conversation so far/, @runtime.identity_content)

    # A normal resume keeps pi's own transcript — no rehydration.
    @runtime.instance_variable_set(:@sandbox_was_resumed, true)
    refute_match(/## Conversation so far/, @runtime.identity_content)
  end

  test "identity_content does not restore history on a conversation's first ever turn" do
    # Fresh sandbox but no prior session (backend_session_id nil) — there is
    # nothing to restore, so the section must stay off.
    @conversation.messages.create!(role: :user, content: "current", streaming_status: :done)
    @runtime.instance_variable_set(:@sandbox_was_resumed, false)

    refute_match(/## Conversation so far/, @runtime.identity_content)
  end
end
