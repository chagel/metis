require "test_helper"
require "opentelemetry/sdk"

class Observability::LangfuseTraceTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "trace@example.com", password: "password123")
    @conversation = @user.conversations.create!(
      title: "Trace test",
      agent_model: { "id" => "gpt-5.5", "name" => "GPT-5.5", "provider" => "openai-codex" },
      runtime_state: { "runtime" => "e2b" }
    )
    @user_message = @conversation.messages.create!(role: :user, content: "hello", streaming_status: :done)
    @assistant_message = @conversation.messages.create!(
      role: :assistant, content: "hi there", streaming_status: :done,
      input_tokens: 100, output_tokens: 40, cache_read_tokens: 10, cost: 0.0042,
      model_key: "gpt-5.5",
      started_at: 3.seconds.ago, finished_at: Time.current,
      tool_calls: [ { "name" => "bash", "args" => { "command" => "ls" }, "output" => "file.txt", "is_error" => false } ]
    )
  end

  def trace = Observability::LangfuseTrace.new(@conversation, @user_message, @assistant_message)

  def with_config(enabled:, include_content: false)
    config = Rails.application.config.x.observability
    was_enabled = config.langfuse_enabled
    was_content = config.langfuse_include_content
    config.langfuse_enabled = enabled
    config.langfuse_include_content = include_content
    yield
  ensure
    config.langfuse_enabled = was_enabled
    config.langfuse_include_content = was_content
  end

  # Route emitted spans through an in-memory exporter so they can be
  # inspected. SimpleSpanProcessor exports on span finish, so the spans are
  # available once the block returns.
  def capture_spans
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    original = OpenTelemetry.method(:tracer_provider)
    OpenTelemetry.define_singleton_method(:tracer_provider) { provider }
    yield
    exporter.finished_spans
  ensure
    OpenTelemetry.define_singleton_method(:tracer_provider, original)
  end

  test "generation attributes carry the turn's model, tokens, and cost" do
    attrs = trace.generation_attributes
    assert_equal "generation", attrs["langfuse.observation.type"]
    assert_equal "gpt-5.5", attrs["gen_ai.request.model"]
    assert_equal 100, attrs["gen_ai.usage.input_tokens"]
    assert_equal 40, attrs["gen_ai.usage.output_tokens"]
    assert_in_delta 0.0042, attrs["gen_ai.usage.cost"], 1e-9
  end

  test "root attributes group by session and user with the provider" do
    attrs = trace.root_attributes
    assert_equal "agent", attrs["langfuse.observation.type"]
    assert_equal @conversation.id.to_s, attrs["session.id"]
    assert_equal @user.id.to_s, attrs["user.id"]
    assert_equal "openai-codex", attrs["gen_ai.system"]
    assert_equal @conversation.team_id.to_s, attrs["langfuse.metadata.team_id"]
  end

  test "content is withheld by default to respect message encryption" do
    with_config(enabled: true, include_content: false) do
      assert_nil trace.root_attributes["input.value"]
      assert_nil trace.generation_attributes["output.value"]
      assert_nil trace.tool_attributes(@assistant_message.tool_calls.first)["output.value"]
    end
  end

  test "content is exported when explicitly opted in" do
    with_config(enabled: true, include_content: true) do
      assert_equal "hello", trace.root_attributes["input.value"]
      assert_equal "hi there", trace.generation_attributes["output.value"]
      assert_equal "file.txt", trace.tool_attributes(@assistant_message.tool_calls.first)["output.value"]
    end
  end

  test "record_turn is a no-op when disabled" do
    with_config(enabled: false) do
      spans = capture_spans do
        Observability::LangfuseTrace.record_turn(
          conversation: @conversation, user_message: @user_message, assistant_message: @assistant_message
        )
      end
      assert_empty spans
    end
  end

  test "record_turn emits a root, generation, and tool span when enabled" do
    with_config(enabled: true) do
      spans = capture_spans do
        Observability::LangfuseTrace.record_turn(
          conversation: @conversation, user_message: @user_message, assistant_message: @assistant_message
        )
      end
      names = spans.map(&:name)
      assert_includes names, "metis.turn"
      assert_includes names, "metis.generation"
      assert_includes names, "metis.tool.bash"
      # tool + generation hang off the turn root (one shared trace)
      assert_equal 1, spans.map(&:trace_id).uniq.size
    end
  end

  test "record_turn rescues and logs instead of raising into the turn" do
    with_config(enabled: true) do
      # finished_at is required for span timestamps; a broken message must
      # not blow up the caller.
      broken = Observability::LangfuseTrace
      assert_nothing_raised do
        broken.record_turn(conversation: @conversation, user_message: @user_message, assistant_message: nil)
      end
    end
  end
end
