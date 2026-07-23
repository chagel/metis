require "test_helper"

class Agent::Adapters::PiTest < ActiveSupport::TestCase
  # Stub `pi --mode rpc`: on a prompt, acks then streams one assistant
  # message (two text deltas) and ends. Single-quoted heredoc so the
  # stub's own \n escapes survive to the child process verbatim.
  PROMPT_STUB = <<~'RUBY'
    require "json"
    $stdout.sync = true
    def emit(obj) = $stdout.write(JSON.generate(obj) + "\n")

    $stdin.each_line do |line|
      msg = JSON.parse(line)
      case msg["type"]
      when "prompt"
        emit({ "id" => msg["id"], "type" => "response", "command" => "prompt", "success" => true })
        emit({ "type" => "agent_start" })
        emit({ "type" => "message_start", "message" => { "id" => "m1", "role" => "assistant" } })
        emit({ "type" => "message_update", "message" => { "id" => "m1" },
               "assistantMessageEvent" => { "type" => "text_delta", "delta" => "Hi" } })
        emit({ "type" => "message_update", "message" => { "id" => "m1" },
               "assistantMessageEvent" => { "type" => "text_delta", "delta" => " there" } })
        emit({ "type" => "message_end", "message" => { "id" => "m1", "role" => "assistant", "content" => "Hi there" } })
        emit({ "type" => "turn_end" })
        emit({ "type" => "agent_end", "messages" => [] })
        emit({ "type" => "agent_settled" })
      when "get_session_stats"
        emit({ "id" => msg["id"], "type" => "response", "command" => "get_session_stats",
               "success" => true, "data" => {
                 "sessionId" => "stub-session-1",
                 "tokens" => { "input" => 120, "output" => 45, "cacheRead" => 30 },
                 "cost" => 0.0123,
                 "contextUsage" => { "tokens" => 195, "contextWindow" => 272000, "percent" => 0.07 }
               } })
      when "get_state"
        emit({ "id" => msg["id"], "type" => "response", "command" => "get_state",
               "success" => true, "data" => {
                 "model" => { "id" => "gpt-5.5", "name" => "GPT-5.5",
                              "provider" => "openai-codex", "contextWindow" => 272000 }
               } })
      end
    end
  RUBY

  # A runtime that yields a caller-supplied stub session, bypassing any
  # real pi process — so adapter behavior is tested in isolation.
  class FakeRuntime
    attr_reader :touched_skill_slugs
    attr_accessor :status_sink

    def initialize(session)
      @session = session
      @touched_skill_slugs = Set.new
    end

    def session_dir
      Pathname.new("/tmp/metis-fake-runtime/sessions")
    end

    def extension_paths
      []
    end

    def runtime_info
      { "runtime" => "fake" }
    end

    def note_skill_touched(slug)
      @touched_skill_slugs << slug if slug
    end

    attr_reader :extension_ui

    def run(pi_args:, extension_ui: nil)
      @extension_ui = extension_ui
      yield @session
    ensure
      @session.close
    end
  end

  def adapter
    Agent::Adapters::Pi.new(conversation: Conversation.new)
  end

  def pi_event(hash)
    PiAgent::Event.new(hash)
  end

  # Adapter wired to a FakeRuntime backed by `ruby -e <stub>` as pi.
  def streaming_adapter(stub)
    client = PiAgent::Client.new(bin: "ruby", args: [ "-e", stub ])
    session = PiAgent::Session.new(client.start)
    Agent::Adapters::Pi.new(conversation: Conversation.new, runtime: FakeRuntime.new(session))
  end

  def create_conversation(**attrs)
    user = User.create!(email: "pi-#{SecureRandom.hex(4)}@example.com", password: "password123")
    user.conversations.create!(attrs)
  end

  # Set config.x.agent deployment defaults for the block, then restore.
  def with_agent_config(**values)
    agent = Rails.application.config.x.agent
    original = values.keys.index_with { |key| agent.public_send(key) }
    values.each { |key, value| agent.public_send("#{key}=", value) }
    yield
  ensure
    original.each { |key, value| agent.public_send("#{key}=", value) }
  end

  # --- translation ---------------------------------------------------

  test "translates message_start" do
    ui = adapter.translate(pi_event("type" => "message_start",
                                    "message" => { "id" => "m1", "role" => "assistant" }))
    assert_equal :message_started, ui.type
    assert_equal "m1", ui[:id]
    assert_equal "assistant", ui[:role]
  end

  test "translates a text_delta message_update" do
    ui = adapter.translate(pi_event("type" => "message_update", "message" => { "id" => "m1" },
                                    "assistantMessageEvent" => { "type" => "text_delta", "delta" => "hello" }))
    assert_equal :text_delta, ui.type
    assert_equal "hello", ui[:delta]
  end

  test "text_delta inserts a paragraph break when pi text crosses into a new message" do
    pi = adapter
    delta = lambda do |id, text|
      pi.translate(pi_event("type" => "message_update", "message" => { "id" => id },
                            "assistantMessageEvent" => { "type" => "text_delta", "delta" => text }))[:delta]
    end

    # First segment is not prefixed; deltas within a message are verbatim;
    # a new message id gets a leading paragraph break.
    assert_equal "Checking tools.",        delta.call("m1", "Checking tools.")
    assert_equal " Found them.",           delta.call("m1", " Found them.")
    assert_equal "\n\nHere is the answer.", delta.call("m2", "Here is the answer.")
  end

  test "translates a thinking_delta message_update to reasoning_delta" do
    ui = adapter.translate(pi_event("type" => "message_update",
                                    "assistantMessageEvent" => { "type" => "thinking_delta", "delta" => "hmm" }))
    assert_equal :reasoning_delta, ui.type
    assert_equal "hmm", ui[:delta]
  end

  test "translates an error message_update" do
    ui = adapter.translate(pi_event("type" => "message_update",
                                    "assistantMessageEvent" => { "type" => "error", "reason" => "error",
                                                                  "error" => "model failed" }))
    assert_equal :error, ui.type
    assert_equal "model failed", ui[:message]
  end

  test "translates message_end with array content" do
    ui = adapter.translate(pi_event("type" => "message_end",
                                    "message" => { "id" => "m1", "role" => "assistant",
                                                   "content" => [ { "type" => "text", "text" => "final answer" } ] }))
    assert_equal :message_finished, ui.type
    assert_equal "final answer", ui[:content]
  end

  test "drops message_end for a non-assistant message so it can't leak into the body" do
    # pi emits message_end for the user prompt and tool-result messages too;
    # their text must never reach the assistant body.
    %w[user tool].each do |role|
      ui = adapter.translate(pi_event("type" => "message_end",
                                      "message" => { "id" => "u1", "role" => role,
                                                     "content" => [ { "type" => "text", "text" => "not the reply" } ] }))
      assert_nil ui, "message_end for role=#{role} should be dropped"
    end
  end

  test "translates tool_execution_start" do
    ui = adapter.translate(pi_event("type" => "tool_execution_start", "toolCallId" => "call_1",
                                    "toolName" => "bash", "args" => { "command" => "ls" }))
    assert_equal :tool_call_started, ui.type
    assert_equal "call_1", ui[:tool_call_id]
    assert_equal "bash", ui[:name]
    assert_equal({ "command" => "ls" }, ui[:args])
    assert_nil ui[:skill_slug]
  end

  test "tool_call_started stamps skill_slug when args reference a skill path" do
    ui = adapter.translate(pi_event("type" => "tool_execution_start", "toolCallId" => "call_1",
                                    "toolName" => "read",
                                    "args" => { "path" => "/metis/workspace/.pi/skills/pptx/SKILL.md" }))
    assert_equal "pptx", ui[:skill_slug]
  end

  test "tool_call_started stamps skill_slug for a bash command touching a skill file" do
    ui = adapter.translate(pi_event("type" => "tool_execution_start", "toolCallId" => "call_1",
                                    "toolName" => "bash",
                                    "args" => { "command" => "cat .pi/skills/eli5/SKILL.md" }))
    assert_equal "eli5", ui[:skill_slug]
  end

  test "translates tool_execution_update progress" do
    ui = adapter.translate(pi_event("type" => "tool_execution_update", "toolCallId" => "call_1",
                                    "partialResult" => { "content" => [ { "type" => "text", "text" => "partial" } ] }))
    assert_equal :tool_call_progress, ui.type
    assert_equal "call_1", ui[:tool_call_id]
    assert_equal "partial", ui[:output]
  end

  test "translates tool_execution_end with error flag" do
    ui = adapter.translate(pi_event("type" => "tool_execution_end", "toolCallId" => "call_1",
                                    "result" => { "content" => [ { "type" => "text", "text" => "boom" } ] },
                                    "isError" => true))
    assert_equal :tool_call_finished, ui.type
    assert_equal "boom", ui[:output]
    assert_equal true, ui[:is_error]
  end

  test "drops agent_end — pi may retry or continue after it" do
    assert_nil adapter.translate(pi_event("type" => "agent_end", "messages" => []))
  end

  test "translates agent_settled to a terminal turn_finished" do
    ui = adapter.translate(pi_event("type" => "agent_settled"))
    assert_equal :turn_finished, ui.type
    assert ui.terminal?
  end

  test "translates extension_error" do
    ui = adapter.translate(pi_event("type" => "extension_error", "error" => "ext blew up"))
    assert_equal :error, ui.type
    assert_equal "ext blew up", ui[:message]
  end

  test "drops events the UI does not render" do
    assert_nil adapter.translate(pi_event("type" => "turn_start"))
    assert_nil adapter.translate(pi_event("type" => "agent_start"))
    assert_nil adapter.translate(pi_event("type" => "queue_update"))
  end

  test "preserves the native event payload on native_ref" do
    raw = { "type" => "agent_settled" }
    assert_equal raw, adapter.translate(pi_event(raw)).native_ref
  end

  # --- streaming -----------------------------------------------------

  test "stream translates a full pi prompt run into UiEvents" do
    events = []
    streaming_adapter(PROMPT_STUB).stream("hi") { |event| events << event }

    assert_equal %i[message_started text_delta text_delta message_finished turn_finished],
                 events.map(&:type)
    assert_equal "Hi", events[1][:delta]
    assert_equal " there", events[2][:delta]
    assert events.last.terminal?
  end

  # The gem drains through agent_settled, so text pi produces in an
  # automatic retry after the first agent_end must reach the UI stream.
  RETRY_STUB = PROMPT_STUB.sub(<<~'BEFORE', <<~'AFTER')
    emit({ "type" => "agent_end", "messages" => [] })
  BEFORE
    emit({ "type" => "agent_end", "messages" => [] })
    emit({ "type" => "agent_start" })
    emit({ "type" => "message_start", "message" => { "id" => "m2", "role" => "assistant" } })
    emit({ "type" => "message_update", "message" => { "id" => "m2" },
           "assistantMessageEvent" => { "type" => "text_delta", "delta" => "Retried tail" } })
    emit({ "type" => "message_end", "message" => { "id" => "m2", "role" => "assistant", "content" => "Retried tail" } })
    emit({ "type" => "turn_end" })
    emit({ "type" => "agent_end", "messages" => [] })
    emit({ "type" => "agent_settled" })
  AFTER

  test "stream keeps output produced after an agent_end retry" do
    events = []
    streaming_adapter(RETRY_STUB).stream("hi") { |event| events << event }

    deltas = events.select { |e| e.type == :text_delta }.map { |e| e[:delta] }
    assert_includes deltas.join, "Retried tail"
    assert_equal [ :turn_finished ], events.map(&:type).select { |t| t == :turn_finished }
    assert events.last.terminal?
  end

  test "stream captures pi's session id" do
    adapter = streaming_adapter(PROMPT_STUB)
    adapter.stream("hi") { |_event| nil }

    assert_equal "stub-session-1", adapter.native_session_id
  end

  test "stream captures token totals, cost, and context usage from session stats" do
    adapter = streaming_adapter(PROMPT_STUB)
    adapter.stream("hi") { |_event| nil }

    assert_equal({ "input" => 120, "output" => 45, "cacheRead" => 30 }, adapter.token_totals)
    assert_in_delta 0.0123, adapter.cost_total, 1e-9
    assert_equal 272000, adapter.context_usage["contextWindow"]
  end

  test "stream captures the resolved model from pi state" do
    adapter = streaming_adapter(PROMPT_STUB)
    adapter.stream("hi") { |_event| nil }

    assert_equal({ "id" => "gpt-5.5", "name" => "GPT-5.5", "provider" => "openai-codex" },
                 adapter.model_info)
  end

  test "stream wires a HostBridge extension_ui handler scoped to the conversation" do
    conversation = create_conversation
    workflow = conversation.team.workflows.create!(
      name: "Ship", steps: [ { "name" => "Build", "prompt" => "go", "gate" => "auto" } ]
    )

    client = PiAgent::Client.new(bin: "ruby", args: [ "-e", PROMPT_STUB ])
    runtime = FakeRuntime.new(PiAgent::Session.new(client.start))
    adapter = Agent::Adapters::Pi.new(conversation: conversation, runtime: runtime)
    adapter.stream("hi") { |_event| nil }

    handler = runtime.extension_ui
    assert handler.respond_to?(:call), "a callable handler is threaded into the runtime"

    req = Struct.new(:title, :placeholder).new("metis:get_workflow", JSON.generate(name: "Ship"))
    assert_equal workflow.name, JSON.parse(handler.call(req))["name"]
  end

  test "token_totals, context_usage, cost_total, and model_info are nil before a run" do
    assert_nil adapter.token_totals
    assert_nil adapter.context_usage
    assert_nil adapter.cost_total
    assert_nil adapter.model_info
  end

  test "runtime_info delegates to the runtime" do
    assert_equal({ "runtime" => "fake" }, streaming_adapter(PROMPT_STUB).runtime_info)
  end

  # A session whose prompt raises `error`, after yielding any raw pi
  # `events` first.
  def timing_out_session(error, events: [])
    session = Object.new
    session.define_singleton_method(:prompt) do |*, **, &block|
      events.each { |raw| block.call(PiAgent::Event.new(raw)) }
      raise error
    end
    def session.close = nil
    session
  end

  def timing_out_adapter(error, events: [])
    Agent::Adapters::Pi.new(conversation: Conversation.new,
                            runtime: FakeRuntime.new(timing_out_session(error, events: events)))
  end

  test "classifies an ack timeout before any pi event as BootTimeout" do
    adapter = timing_out_adapter(PiAgent::TimeoutError.new("Future timed out after 30s"))

    assert_raises(Agent::Adapters::BootTimeout) { adapter.stream("hi") { |_e| nil } }
  end

  test "an ack timeout after pi responded stays a plain TimeoutError" do
    adapter = timing_out_adapter(PiAgent::TimeoutError.new("Future timed out after 30s"),
                                 events: [ { "type" => "agent_start" } ])

    assert_raises(PiAgent::TimeoutError) { adapter.stream("hi") { |_e| nil } }
  end

  test "an event-stream timeout stays a plain TimeoutError" do
    adapter = timing_out_adapter(PiAgent::TimeoutError.new("No event received within 300s"))

    assert_raises(PiAgent::TimeoutError) { adapter.stream("hi") { |_e| nil } }
  end

  # --- argument building ---------------------------------------------

  test "pi_args points at the workspace session directory" do
    conversation = create_conversation
    args = Agent::Adapters::Pi.new(conversation: conversation).pi_args

    assert_includes args, "--mode"
    assert_includes args, "rpc"
    dir = args[args.index("--session-dir") + 1]
    assert_match %r{/u#{conversation.user_id}/c#{conversation.id}/sessions\z}, dir
  end

  test "pi_args loads the app's bundled pi extensions" do
    args = Agent::Adapters::Pi.new(conversation: create_conversation).pi_args
    loaded = args.each_index.select { |i| args[i] == "--extension" }.map { |i| args[i + 1] }

    assert loaded.any? { |path| path.end_with?(".pi/extensions/web-tools/index.ts") },
           "the web-tools extension is passed to pi"
  end

  # --- touched-skill slug collection ---------------------------------

  # pi's tool_execution_start carries args; _end does not. We hook
  # start so the path is available.
  def start_event(name, args)
    pi_event("type" => "tool_execution_start",
             "toolName" => name,
             "args" => args,
             "toolCallId" => "tc-1")
  end

  test "translate records the slug for a write tool that targets a team-skill path" do
    adapter = streaming_adapter(PROMPT_STUB)
    adapter.translate(start_event("write", { "path" => "/metis/workspace/.pi/skills/haiku-mode/SKILL.md" }))
    assert_equal Set["haiku-mode"], adapter.instance_variable_get(:@runtime).touched_skill_slugs
  end

  test "translate records the slug for an edit tool that targets a team-skill path" do
    adapter = streaming_adapter(PROMPT_STUB)
    adapter.translate(start_event("edit", { "path" => "/metis/workspace/.pi/skills/tldr/SKILL.md" }))
    assert_equal Set["tldr"], adapter.instance_variable_get(:@runtime).touched_skill_slugs
  end

  test "translate records all skill slugs mentioned in a bash command (heuristic)" do
    adapter = streaming_adapter(PROMPT_STUB)
    adapter.translate(start_event("bash",
      { "command" => "cp /metis/workspace/.pi/skills/eli5/SKILL.md /metis/workspace/.pi/skills/eli5-copy/SKILL.md" }))
    assert_equal Set["eli5", "eli5-copy"], adapter.instance_variable_get(:@runtime).touched_skill_slugs
  end

  test "translate ignores read events — only writes register" do
    adapter = streaming_adapter(PROMPT_STUB)
    adapter.translate(start_event("read", { "path" => "/metis/workspace/.pi/skills/haiku-mode/SKILL.md" }))
    assert_empty adapter.instance_variable_get(:@runtime).touched_skill_slugs
  end

  test "translate ignores writes outside the .pi/skills/ tree" do
    adapter = streaming_adapter(PROMPT_STUB)
    adapter.translate(start_event("write", { "path" => "/metis/workspace/random.md" }))
    assert_empty adapter.instance_variable_get(:@runtime).touched_skill_slugs
  end

  test "pi_args omits --continue for a fresh conversation" do
    args = Agent::Adapters::Pi.new(conversation: create_conversation).pi_args
    refute_includes args, "--continue"
  end

  test "pi_args includes --continue once a pi session exists" do
    conversation = create_conversation(backend_session_id: "sess-abc")
    args = Agent::Adapters::Pi.new(conversation: conversation).pi_args
    assert_includes args, "--continue"
  end

  test "pi_args carries credential flags from the conversation settings" do
    conversation = create_conversation(
      settings: { "model" => "anthropic/claude-sonnet-4-5", "provider" => "anthropic" }
    )
    with_agent_config(api_keys: { "anthropic" => "sk-test" }) do
      args = Agent::Adapters::Pi.new(conversation: conversation).pi_args

      assert_equal "anthropic/claude-sonnet-4-5", args[args.index("--model") + 1]
      assert_equal "anthropic", args[args.index("--provider") + 1]
      assert_equal "sk-test", args[args.index("--api-key") + 1]
    end
  end

  test "pi_args omits --api-key when no key is configured for the provider" do
    conversation = create_conversation(settings: { "provider" => "anthropic" })
    with_agent_config(api_keys: {}) do
      args = Agent::Adapters::Pi.new(conversation: conversation).pi_args

      assert_includes args, "--provider"
      refute_includes args, "--api-key"
    end
  end

  test "credential flags fall back to the deployment config when settings are empty" do
    conversation = create_conversation
    with_agent_config(provider: "anthropic", model: "anthropic/claude-sonnet-4-5",
                      api_keys: { "anthropic" => "sk-deploy" }) do
      args = Agent::Adapters::Pi.new(conversation: conversation).pi_args

      assert_equal "anthropic/claude-sonnet-4-5", args[args.index("--model") + 1]
      assert_equal "anthropic", args[args.index("--provider") + 1]
      assert_equal "sk-deploy", args[args.index("--api-key") + 1]
    end
  end

  test "conversation settings override the deployment config" do
    conversation = create_conversation(settings: { "provider" => "openai", "model" => "openai/gpt-5" })
    with_agent_config(provider: "anthropic", model: "anthropic/claude-sonnet-4-5") do
      args = Agent::Adapters::Pi.new(conversation: conversation).pi_args

      assert_equal "openai/gpt-5", args[args.index("--model") + 1]
      assert_equal "openai", args[args.index("--provider") + 1]
    end
  end

  test "the deployment api key is matched to the conversation's provider" do
    conversation = create_conversation(settings: { "provider" => "openai" })
    with_agent_config(api_keys: { "anthropic" => "sk-ant", "openai" => "sk-oai" }) do
      args = Agent::Adapters::Pi.new(conversation: conversation).pi_args

      assert_equal "sk-oai", args[args.index("--api-key") + 1]
    end
  end

  # --- attachments ---------------------------------------------------

  Upload = Struct.new(:filename, :content_type, :bytes) do
    def download = bytes
  end

  test "pi_images builds inline pi image content from image attachments" do
    png = Upload.new("shot.png", "image/png", "fake-png-bytes")
    images = adapter.send(:pi_images, [ png ])

    assert_equal 1, images.size
    assert_instance_of PiAgent::Image, images.first
    assert_equal "image/png", images.first.mime_type
  end

  test "prompt_with_files appends a note naming the staged files" do
    files = [ Upload.new("data.csv", "text/csv", ""), Upload.new("notes.txt", "text/plain", "") ]
    text = adapter.send(:prompt_with_files, "summarize these", files)

    assert_includes text, "summarize these"
    assert_includes text, "data.csv"
    assert_includes text, "notes.txt"
  end

  test "prompt_with_files returns the input unchanged when there are no files" do
    assert_equal "just text", adapter.send(:prompt_with_files, "just text", [])
  end
end
