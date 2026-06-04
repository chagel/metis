require "test_helper"

class Agent::UiEventTest < ActiveSupport::TestCase
  test "builds an event with a known type" do
    event = Agent::UiEvent.new(:text_delta, data: { delta: "hi" }, native_ref: { "raw" => true })
    assert_equal :text_delta, event.type
    assert_equal "hi", event[:delta]
    assert_equal({ "raw" => true }, event.native_ref)
  end

  test "rejects an unknown type" do
    assert_raises(ArgumentError) { Agent::UiEvent.new(:nonsense) }
  end

  test "runtime_status is a known type carrying a phase and message" do
    event = Agent::UiEvent.new(:runtime_status, data: { phase: :creating, message: "Creating sandbox" })
    assert_equal :runtime_status, event.type
    assert_equal "Creating sandbox", event[:message]
    refute event.terminal?
  end

  test "turn_finished is terminal" do
    assert Agent::UiEvent.new(:turn_finished).terminal?
  end

  test "non-terminal types are not terminal" do
    refute Agent::UiEvent.new(:text_delta, data: { delta: "x" }).terminal?
    refute Agent::UiEvent.new(:message_finished).terminal?
  end

  test "error? is true only for error events" do
    assert Agent::UiEvent.new(:error, data: { message: "boom" }).error?
    refute Agent::UiEvent.new(:text_delta, data: { delta: "x" }).error?
  end

  test "data is frozen" do
    assert Agent::UiEvent.new(:text_delta, data: { delta: "x" }).data.frozen?
  end

  test "to_h round-trips type, data, native_ref" do
    event = Agent::UiEvent.new(:text_delta, data: { delta: "x" }, native_ref: { "n" => 1 })
    assert_equal({ type: :text_delta, data: { delta: "x" }, native_ref: { "n" => 1 } }, event.to_h)
  end
end
