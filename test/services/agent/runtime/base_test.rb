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
end
