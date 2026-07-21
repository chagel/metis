require "test_helper"

class ChatJobTest < ActiveSupport::TestCase
  # Fake adapter that replays a canned Agent::UiEvent stream.
  class FakeAdapter
    attr_reader :native_session_id, :token_totals, :context_usage, :cost_total,
                :model_info, :runtime_info, :artifacts

    def initialize(events, native_session_id: nil, token_totals: nil, context_usage: nil,
                   cost_total: nil, model_info: nil, runtime_info: nil, artifacts: [])
      @events = events
      @native_session_id = native_session_id
      @token_totals = token_totals
      @context_usage = context_usage
      @cost_total = cost_total
      @model_info = model_info
      @runtime_info = runtime_info
      @artifacts = artifacts
    end

    def stream(_input, images: [], files: [])
      @events.each { |event| break if @aborted; yield event }
    end

    def abort = (@aborted = true)
  end

  setup do
    @user = User.create!(email: "job@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Job test")
    @user_message = @conversation.messages.create!(role: :user, content: "hi", streaming_status: :done)
    @assistant_message = @conversation.messages.create!(role: :assistant, content: "", streaming_status: :pending)
  end

  # Swap Agent::Adapters.for for the duration of the block.
  def with_adapter(adapter)
    original = Agent::Adapters.method(:for)
    Agent::Adapters.define_singleton_method(:for) { |*, **| adapter }
    yield
  ensure
    Agent::Adapters.define_singleton_method(:for, original)
  end

  def perform_job(adapter)
    with_adapter(adapter) do
      ChatJob.perform_now(@conversation.id, @user_message.id, @assistant_message.id)
    end
  end

  def run_with(events, **adapter_opts)
    perform_job(FakeAdapter.new(events, **adapter_opts))
  end

  test "accumulates text deltas and marks the assistant message done" do
    run_with([
               Agent::UiEvent.new(:message_started, data: { role: "assistant" }),
               Agent::UiEvent.new(:text_delta, data: { delta: "Hello" }),
               Agent::UiEvent.new(:text_delta, data: { delta: " world" }),
               Agent::UiEvent.new(:message_finished, data: { content: "Hello world" }),
               Agent::UiEvent.new(:turn_finished)
             ])

    @assistant_message.reload
    assert_equal "Hello world", @assistant_message.content
    assert @assistant_message.done?
  end

  test "persists pi's authoritative message text when the delta stream ends short" do
    # openai ends the text_delta stream a few chars before the message's real
    # text; message_end carries the complete content. The saved reply must be
    # the complete one, not the truncated delta accumulation.
    run_with([
               Agent::UiEvent.new(:text_delta, data: { delta: "I'm Metis, running as `openai/gpt-5.4-mini" }),
               Agent::UiEvent.new(:message_finished,
                                  data: { id: "m1", content: "I'm Metis, running as `openai/gpt-5.4-mini`." }),
               Agent::UiEvent.new(:turn_finished)
             ])

    assert_equal "I'm Metis, running as `openai/gpt-5.4-mini`.", @assistant_message.reload.content
  end

  test "joins multiple finished message segments with a blank line" do
    run_with([
               Agent::UiEvent.new(:text_delta, data: { delta: "First" }),
               Agent::UiEvent.new(:message_finished, data: { id: "m1", content: "First part." }),
               Agent::UiEvent.new(:text_delta, data: { delta: "Second" }),
               Agent::UiEvent.new(:message_finished, data: { id: "m2", content: "Second part." }),
               Agent::UiEvent.new(:turn_finished)
             ])

    assert_equal "First part.\n\nSecond part.", @assistant_message.reload.content
  end

  test "falls back to the streamed text when no message finalized" do
    # A turn that errors before any message_end still saves what streamed.
    run_with([
               Agent::UiEvent.new(:text_delta, data: { delta: "partial answer" }),
               Agent::UiEvent.new(:error, data: { message: "boom" }),
               Agent::UiEvent.new(:turn_finished)
             ])

    assert_equal "partial answer", @assistant_message.reload.content
  end

  test "strips U+0000 from a tool call's output so the turn persists" do
    run_with([
               Agent::UiEvent.new(:tool_call_started,
                                  data: { tool_call_id: "t1", name: "bash", args: { "command" => "od file" } }),
               Agent::UiEvent.new(:tool_call_finished,
                                  data: { tool_call_id: "t1",
                                          output: "ok\x00here", is_error: false }),
               Agent::UiEvent.new(:turn_finished)
             ])

    @assistant_message.reload
    assert_predicate @assistant_message, :done?, "turn should persist instead of getting stuck"
    assert_equal "okhere", @assistant_message.tool_calls.sole["output"]
  end

  test "strips U+0000 from Hash keys nested in a tool call's output" do
    # A tool-call output Hash whose KEY contains U+0000 — the original
    # scrub_null_bytes used transform_values and missed keys, leaving
    # the poisoned key to crash the JSON write the scrub was meant to
    # prevent.
    run_with([
               Agent::UiEvent.new(:tool_call_started,
                                  data: { tool_call_id: "t-k", name: "read_files",
                                          args: { "paths" => [ "ok" ] } }),
               Agent::UiEvent.new(:tool_call_finished,
                                  data: { tool_call_id: "t-k",
                                          output: { "path\x00bad" => "data" },
                                          is_error: false }),
               Agent::UiEvent.new(:turn_finished)
             ])

    @assistant_message.reload
    assert_predicate @assistant_message, :done?
    output = @assistant_message.tool_calls.sole["output"]
    assert_equal({ "pathbad" => "data" }, output)
  end

  test "strips U+0000 from streamed text and reasoning" do
    run_with([
               Agent::UiEvent.new(:text_delta, data: { delta: "hi\x00bye" }),
               Agent::UiEvent.new(:reasoning_delta, data: { delta: "think\x00ing" }),
               Agent::UiEvent.new(:turn_finished)
             ])

    @assistant_message.reload
    assert_equal "hibye", @assistant_message.content
    assert_equal "thinking", @assistant_message.reasoning
  end

  test "fail_message reloads before updating so a poisoned in-memory state can't block recovery" do
    # Simulate the original bug: the persist update has already been
    # attempted and rolled back, leaving the in-memory record dirty
    # with content PostgreSQL would refuse. fail_message must reload
    # to drop those dirty attrs, otherwise it rolls back too and the
    # message stays frozen mid-turn.
    @assistant_message.streaming_status = :streaming
    @assistant_message.content = "ok\x00here"

    ChatJob.new.send(:fail_message, @assistant_message, nil, "the agent run failed.")

    @assistant_message.reload
    assert_predicate @assistant_message, :errored?
  end

  test "persists the reasoning log and tool calls so they survive a refresh" do
    run_with([
               Agent::UiEvent.new(:reasoning_delta, data: { delta: "thinking " }),
               Agent::UiEvent.new(:reasoning_delta, data: { delta: "hard" }),
               Agent::UiEvent.new(:tool_call_started,
                                  data: { tool_call_id: "t1", name: "bash", args: { "command" => "ls" } }),
               Agent::UiEvent.new(:tool_call_finished,
                                  data: { tool_call_id: "t1", output: "file.txt", is_error: false }),
               Agent::UiEvent.new(:turn_finished)
             ])

    @assistant_message.reload
    assert_equal "thinking hard", @assistant_message.reasoning

    call = @assistant_message.tool_calls.sole
    assert_equal "bash", call["name"]
    assert_equal({ "command" => "ls" }, call["args"])
    assert_equal "file.txt", call["output"]
    assert_equal "done", call["status"]
  end

  test "marks the message errored when an error event arrives" do
    run_with([
               Agent::UiEvent.new(:text_delta, data: { delta: "partial" }),
               Agent::UiEvent.new(:error, data: { message: "boom" }),
               Agent::UiEvent.new(:turn_finished)
             ])

    assert @assistant_message.reload.errored?
  end

  test "persists pi's session id to the conversation" do
    run_with([ Agent::UiEvent.new(:text_delta, data: { delta: "hi" }),
              Agent::UiEvent.new(:turn_finished) ],
             native_session_id: "sess-xyz")

    assert_equal "sess-xyz", @conversation.reload.backend_session_id
  end

  test "leaves backend_session_id unset when the adapter reports none" do
    run_with([ Agent::UiEvent.new(:turn_finished) ])
    assert_nil @conversation.reload.backend_session_id
  end

  test "touches the conversation after a successful run" do
    before = @conversation.updated_at
    travel 1.second do
      run_with([ Agent::UiEvent.new(:text_delta, data: { delta: "x" }),
                Agent::UiEvent.new(:turn_finished) ])
    end
    assert_operator @conversation.reload.updated_at, :>, before
  end

  test "records this turn's token usage on the assistant message" do
    run_with([ Agent::UiEvent.new(:turn_finished) ],
             token_totals: { "input" => 100, "output" => 40, "cacheRead" => 10 })

    @assistant_message.reload
    assert_equal 100, @assistant_message.input_tokens
    assert_equal 40, @assistant_message.output_tokens
    assert_equal 10, @assistant_message.cache_read_tokens
  end

  test "token usage is this turn's rise over earlier turns' cumulative totals" do
    @conversation.messages.create!(
      role: :assistant, content: "earlier", streaming_status: :done,
      input_tokens: 70, output_tokens: 25, cache_read_tokens: 5
    )
    run_with([ Agent::UiEvent.new(:turn_finished) ],
             token_totals: { "input" => 100, "output" => 40, "cacheRead" => 10 })

    @assistant_message.reload
    assert_equal 30, @assistant_message.input_tokens
    assert_equal 15, @assistant_message.output_tokens
    assert_equal 5, @assistant_message.cache_read_tokens
  end

  test "records this turn's cost on the assistant message" do
    run_with([ Agent::UiEvent.new(:turn_finished) ], cost_total: 0.0042)

    assert_in_delta 0.0042, @assistant_message.reload.cost, 1e-9
  end

  test "cost is this turn's rise over earlier turns' cumulative cost" do
    @conversation.messages.create!(
      role: :assistant, content: "earlier", streaming_status: :done, cost: 0.30
    )
    run_with([ Agent::UiEvent.new(:turn_finished) ], cost_total: 0.45)

    assert_in_delta 0.15, @assistant_message.reload.cost, 1e-9
  end

  test "records the model that served this turn on the message" do
    run_with([ Agent::UiEvent.new(:turn_finished) ],
             model_info: { "id" => "gpt-5.5", "name" => "GPT-5.5", "provider" => "openai-codex" })

    assert_equal "gpt-5.5", @assistant_message.reload.model_key
  end

  test "tolerates a provider that returns no usage stats (earendil-works/pi#5386)" do
    # Ollama-style: pi omits session stats, so the adapter reports nil for
    # every usage field. The turn must still finish, just without numbers.
    run_with([ Agent::UiEvent.new(:text_delta, data: { delta: "hi" }),
              Agent::UiEvent.new(:turn_finished) ],
             token_totals: nil, cost_total: nil, model_info: nil)

    @assistant_message.reload
    assert_predicate @assistant_message, :done?
    assert_nil @assistant_message.cost
    assert_nil @assistant_message.input_tokens
  end

  test "stores the context-window usage on the conversation" do
    run_with([ Agent::UiEvent.new(:turn_finished) ],
             context_usage: { "tokens" => 195, "contextWindow" => 272000, "percent" => 0.07 })

    assert_equal 272000, @conversation.reload.context_usage["contextWindow"]
  end

  test "stores the resolved model on the conversation" do
    run_with([ Agent::UiEvent.new(:turn_finished) ],
             model_info: { "id" => "gpt-5.5", "name" => "GPT-5.5", "provider" => "openai-codex" })

    assert_equal "GPT-5.5", @conversation.reload.agent_model["name"]
    assert_equal "openai-codex", @conversation.agent_model["provider"]
  end

  test "marks the message errored when the adapter raises" do
    raiser = Object.new
    def raiser.stream(*)
      raise "pi crashed"
    end

    perform_job(raiser)
    assert @assistant_message.reload.errored?
  end

  test "a turn that raises mid-stream still records where it ran" do
    # The failed turn may have written a workspace already —
    # EvictDockerWorkspacesJob can only find it through runtime_state.
    adapter = FakeAdapter.new([], runtime_info: { "runtime" => "docker" })
    def adapter.stream(*)
      raise "pi crashed"
    end

    perform_job(adapter)

    assert_equal "docker", @conversation.reload.runtime_state["runtime"]
    assert @assistant_message.reload.errored?
  end

  test "records where the turn ran on the conversation" do
    run_with([ Agent::UiEvent.new(:turn_finished) ],
             runtime_info: { "runtime" => "e2b", "sandbox_id" => "sbx-1" })

    assert_equal({ "runtime" => "e2b", "sandbox_id" => "sbx-1" }, @conversation.reload.runtime_state)
  end

  test "aborts the turn and marks it canceled when cancellation is requested" do
    @assistant_message.update!(started_at: 1.minute.ago)
    @conversation.request_cancel!
    events = Array.new(40) { Agent::UiEvent.new(:text_delta, data: { delta: "x" }) }
    events << Agent::UiEvent.new(:turn_finished)

    run_with(events)

    assert @assistant_message.reload.canceled?
  end

  test "a turn with no cancellation request finishes normally" do
    @assistant_message.update!(started_at: 1.minute.ago)
    events = Array.new(40) { Agent::UiEvent.new(:text_delta, data: { delta: "x" }) }
    events << Agent::UiEvent.new(:turn_finished)

    run_with(events)

    assert @assistant_message.reload.done?
  end

  test "stamps finished_at so a completed turn has a duration" do
    @assistant_message.update!(started_at: 3.seconds.ago)
    run_with([ Agent::UiEvent.new(:turn_finished) ])

    @assistant_message.reload
    assert_not_nil @assistant_message.finished_at
    assert_operator @assistant_message.duration, :>, 0
  end

  test "attaches the runtime's artifacts to the assistant message" do
    artifacts = [
      { filename: "report.csv", io: StringIO.new("a,b\n1,2\n"), content_type: "text/csv" },
      { filename: "chart.png",  io: StringIO.new("fakepng"),    content_type: "image/png" }
    ]
    run_with([ Agent::UiEvent.new(:turn_finished) ], artifacts: artifacts)

    @assistant_message.reload
    assert_equal 2, @assistant_message.artifacts.count
    names = @assistant_message.artifacts.map { |a| a.filename.to_s }
    assert_includes names, "report.csv"
    assert_includes names, "chart.png"
  end

  test "no artifacts attached when the runtime published none" do
    run_with([ Agent::UiEvent.new(:turn_finished) ])

    assert_not @assistant_message.reload.artifacts.attached?
  end

  test "attaches the runtime's artifacts even when the stream raises mid-turn" do
    # The runtime collects in its own ensure, so partial work is already
    # buffered by the time the adapter re-raises.
    crasher = Class.new do
      attr_reader :artifacts
      def initialize(artifacts) = (@artifacts = artifacts)
      def stream(*) = raise "pi crashed"
      def native_session_id = nil
      def token_totals = nil
      def context_usage = nil
      def model_info = nil
      def runtime_info = nil
    end
    artifacts = [ { filename: "partial.txt", io: StringIO.new("got this far"), content_type: "text/plain" } ]

    perform_job(crasher.new(artifacts))

    @assistant_message.reload
    assert @assistant_message.errored?, "still marked errored — the crash is not silenced"
    assert_equal 1, @assistant_message.artifacts.count
    assert_equal "partial.txt", @assistant_message.artifacts.first.filename.to_s
  end

  # Raises `error` on the first `failures` stream calls, then replays
  # `events` normally.
  class FailingAdapter < FakeAdapter
    attr_reader :stream_calls

    def initialize(events, error:, failures: 1)
      super(events)
      @error = error
      @failures = failures
      @stream_calls = 0
    end

    def stream(input, images: [], files: [], &block)
      @stream_calls += 1
      raise @error if @stream_calls <= @failures

      super
    end
  end

  test "retries once when the adapter reports a boot timeout" do
    adapter = FailingAdapter.new(
      [ Agent::UiEvent.new(:text_delta, data: { delta: "recovered" }),
        Agent::UiEvent.new(:turn_finished) ],
      error: Agent::Adapters::BootTimeout.new("Future timed out after 30s")
    )

    perform_job(adapter)

    assert_equal 2, adapter.stream_calls
    @assistant_message.reload
    assert @assistant_message.done?
    assert_equal "recovered", @assistant_message.content
  end

  test "gives up after a second consecutive boot timeout" do
    adapter = FailingAdapter.new(
      [ Agent::UiEvent.new(:turn_finished) ],
      error: Agent::Adapters::BootTimeout.new("Future timed out after 30s"), failures: 2
    )

    perform_job(adapter)

    assert_equal 2, adapter.stream_calls
    assert @assistant_message.reload.errored?
  end

  test "does not retry other agent timeouts" do
    # Only the adapter-classified boot timeout is safe to re-prompt; a
    # plain timeout may follow an acked, running turn.
    adapter = FailingAdapter.new(
      [ Agent::UiEvent.new(:turn_finished) ],
      error: PiAgent::TimeoutError.new("No event received within 300s")
    )

    perform_job(adapter)

    assert_equal 1, adapter.stream_calls
    assert @assistant_message.reload.errored?
  end

  test "stamps finished_at even when the turn fails" do
    raiser = Object.new
    def raiser.stream(*)
      raise "pi crashed"
    end

    perform_job(raiser)
    assert_not_nil @assistant_message.reload.finished_at
  end
end
