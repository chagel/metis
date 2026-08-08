require "test_helper"

# Asserts what pi actually puts on the RPC wire, by running it. Every other
# pi test in this suite stubs the wire, so a stub that drifts from the real
# protocol reads as green — which is exactly how pi 0.84 silently broke
# text segmentation (see Adapters::Pi#segmented_delta).
#
# Opt-in: it spends real tokens and needs pi on PATH plus a provider key.
#
#   PI_CONTRACT=1 foreman run bin/rails test test/contracts/pi_wire_contract_test.rb
#
# `foreman run` loads .env, which is where the provider key lives. Run this
# on every pi version bump — that is the moment the assumptions can rot.
class PiWireContractTest < ActiveSupport::TestCase
  # Forces pi to split its reply across two assistant messages with a tool
  # call between — the shape whose boundary Metis has to detect.
  PROMPT = "Reply with the single word Checking (no punctuation, no other text). " \
           "Then use your bash tool to run `echo hi`. " \
           "Then reply with the single word Done (no punctuation, no other text)."

  setup do
    skip "set PI_CONTRACT=1 to run the live pi wire contract" unless ENV["PI_CONTRACT"]
  end

  # One turn serves every assertion below — setup runs per test, and each
  # capture is a paid round trip.
  def self.captured
    @captured ||= begin
      user = User.create!(email: "wire-#{SecureRandom.hex(4)}@example.com", password: "password123")
      conversation = user.conversations.create!(team: user.personal_team)
      raw, ui = [], []
      adapter = Agent::Adapters::Pi.new(conversation: conversation)
      adapter.define_singleton_method(:translate) do |event|
        raw << event.raw
        super(event)
      end
      adapter.stream(PROMPT) { |event| ui << event }
      { raw: raw, ui: ui }
    end
  end

  test "message_update carries only the delta — no cumulative message, no partial" do
    updates = raw.select { |event| event["type"] == "message_update" }

    assert_predicate updates, :any?, "pi emitted no message_update events"
    assert_equal [], updates.select { |event| event.key?("message") },
      "pi 0.84 strips the cumulative message snapshot; Adapters::Pi must not read it"
    assert_equal [], updates.select { |event| event.dig("assistantMessageEvent", "partial") }
    assert_equal %w[assistantMessageEvent type], updates.flat_map(&:keys).uniq.sort
  end

  test "wire messages carry no id, so message_start is the only segment signal" do
    bounded = raw.select { |event| %w[message_start message_end].include?(event["type"]) }

    assert_predicate bounded, :any?
    assert_equal [], bounded.select { |event| event.dig("message", "id") },
      "pi supplies no message id — segmentation cannot key off one"
    assert_operator assistant_starts.size, :>=, 2,
      "the prompt should have produced more than one assistant message"
  end

  test "a new assistant segment can begin without leading whitespace" do
    # The premise of #segmented_delta: without an inserted break these fuse.
    assert_operator first_deltas.size, :>=, 2
    assert first_deltas.drop(1).any? { |delta| delta.present? && !delta.start_with?(/\s/) },
      "no segment began flush against the previous one — the prompt no longer " \
      "exercises segmentation, so this contract proves nothing"
  end

  test "the adapter separates the segments it streams" do
    streamed = ui.select { |event| event.type == :text_delta }.map { |event| event[:delta] }.join

    assert_includes streamed, "\n\n",
      "ChatJob's fallback buffer reads these deltas raw — fused here means fused there"
  end

  private

  def raw = self.class.captured[:raw]
  def ui = self.class.captured[:ui]

  def assistant_starts
    raw.select { |event| event["type"] == "message_start" && event.dig("message", "role") == "assistant" }
  end

  # The first text delta of each assistant message, in order.
  def first_deltas
    deltas = []
    awaiting = false
    raw.each do |event|
      case event["type"]
      when "message_start"
        awaiting = event.dig("message", "role") == "assistant"
      when "message_update"
        next unless event.dig("assistantMessageEvent", "type") == "text_delta"

        if awaiting
          deltas << event.dig("assistantMessageEvent", "delta")
          awaiting = false
        end
      end
    end
    deltas
  end
end
