require "test_helper"

# The microsandbox-rb gem rides an optional bundler group and is absent in
# CI. The runtime lazy-requires it only when ::Microsandbox is undefined, so
# this minimal stand-in keeps the tests exercising the real provisioning
# paths (Sandbox.create is stubbed per test).
unless defined?(Microsandbox)
  module Microsandbox
    class Error < StandardError; end

    # Mirrors the gem's cursor-paginated listing result (gem 0.11+).
    class SandboxPage
      include Enumerable

      attr_reader :sandboxes, :next_cursor

      def initialize(sandboxes, next_cursor = nil)
        @sandboxes = sandboxes
        @next_cursor = next_cursor
      end

      def each(&) = @sandboxes.each(&)
      def last_page? = @next_cursor.nil?
    end

    module RootDisk
      def self.tmpfs(size_mib = nil)
        h = { "kind" => "tmpfs" }
        h["size_mib"] = Integer(size_mib) if size_mib
        h
      end
    end

    module Sandbox
      def self.create(*, **)
        raise NotImplementedError, "stub ::Microsandbox::Sandbox.create in tests"
      end

      def self.list = SandboxPage.new([])

      def self.list_with(labels: {}, limit: nil, cursor: nil) = SandboxPage.new([])

      def self.remove(_name) = nil
    end
  end
end

class Agent::Runtime::MicrosandboxTest < ActiveSupport::TestCase
  class FakeSandbox
    attr_reader :name, :stops, :kills

    def initialize(name = "metis-c1-abcd")
      @name = name
      @stops = 0
      @kills = 0
    end

    def stop = (@stops += 1)
    def kill = (@kills += 1)
    def stopped? = @stops.positive?
  end

  setup do
    @user = User.create!(email: "rt-msb@example.com", password: "password123")
    @conversation = @user.conversations.create!
    @runtime = Agent::Runtime::Microsandbox.new(conversation: @conversation)
    @workspace = Agent::Workspace.persistent(@conversation)
  end

  teardown do
    FileUtils.rm_rf(Agent::Workspace::PERSISTENT_ROOT.join("u#{@user.id}"))
  end

  # Swap PiAgent.session so #run never opens a real transport.
  def with_pi_session(session, &block)
    with_stub(PiAgent, :session, ->(*, **) { session }, &block)
  end

  def fake_session
    session = Object.new
    def session.closed? = @closed
    def session.close = (@closed = true)
    session
  end

  # Capture Sandbox.create calls and hand back `sandbox`.
  def with_sandbox_create(sandbox)
    captured = []
    with_stub(::Microsandbox::Sandbox, :create,
              ->(name, **params) { captured << [ name, params ]; sandbox }) do
      yield captured
    end
  end

  def with_agent_config(**overrides)
    config = Rails.application.config.x.agent
    originals = overrides.keys.index_with { |key| config.public_send(key) }
    overrides.each { |key, value| config.public_send("#{key}=", value) }
    yield
  ensure
    originals.each { |key, value| config.public_send("#{key}=", value) }
  end

  test "resolves from the runtime registry" do
    assert_equal Agent::Runtime::Microsandbox, Agent::Runtime.runtime_class(:microsandbox)
  end

  test "session_dir is the in-guest session path" do
    assert_equal Pathname.new("/metis/sessions"), @runtime.session_dir
  end

  test "extension_paths ride the read-only extensions bind mount" do
    paths = @runtime.extension_paths.map(&:to_s)
    assert_includes paths, "/metis-extensions/web-tools/index.ts"
  end

  test "run boots a disposable VM against the persistent scope mount" do
    sandbox = FakeSandbox.new
    yielded = nil

    with_sandbox_create(sandbox) do |captured|
      with_pi_session(fake_session) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) do |s|
          yielded = s
          assert Dir.exist?(@workspace.workspace_dir), "workspace provisioned"
        end
      end

      name, params = captured.first
      assert_match(/\Ametis-c#{@conversation.id}-/, name)
      assert_equal Agent::Runtime::Microsandbox.image, params[:image]
      assert params[:ephemeral], "the VM's stored state must be reaped on stop"
      assert_equal({ "app" => "metis" }, params[:labels])
      refute params.key?(:root_disk), "the turn VM keeps the managed on-disk upper"
      assert_equal "/metis/workspace", params[:workdir]
      assert_equal({ bind: @workspace.scope_dir.to_s }, params[:volumes]["/metis"])
      assert_equal true, params[:volumes]["/metis-extensions"][:ro]
    end

    refute_nil yielded
    assert sandbox.stopped?, "the VM is stopped at end of turn"
  end

  test "run stops the VM even when the turn raises" do
    sandbox = FakeSandbox.new

    with_sandbox_create(sandbox) do |_captured|
      with_pi_session(fake_session) do
        assert_raises(RuntimeError) do
          @runtime.run(pi_args: [ "--mode", "rpc" ]) { raise "turn blew up" }
        end
      end
    end

    assert sandbox.stopped?
  end

  test "a stop failure escalates to a force-kill" do
    sandbox = FakeSandbox.new
    def sandbox.stop = raise(::Microsandbox::Error, "already gone")
    turn_ran = false

    with_sandbox_create(sandbox) do |_captured|
      with_pi_session(fake_session) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) { turn_ran = true }
      end
    end

    assert turn_ran, "the turn must complete despite the stop failure"
    assert_equal 1, sandbox.kills,
      "a VM that refuses to stop would hold its CPU/memory until MAX_DURATION"
  end

  test "a stop and kill that both fail are logged, not raised" do
    sandbox = FakeSandbox.new
    def sandbox.stop = raise(::Microsandbox::Error, "already gone")
    def sandbox.kill = raise(::Microsandbox::Error, "gone too")
    turn_ran = false

    with_sandbox_create(sandbox) do |_captured|
      with_pi_session(fake_session) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) { turn_ran = true }
      end
    end

    assert turn_ran, "teardown must never crash a turn the user already saw stream"
  end

  test "load_gem translates a missing optional gem into a StandardError" do
    with_stub(Agent::Runtime::Microsandbox, :gem_loaded?, -> { false }) do
      with_stub(Agent::Runtime::Microsandbox, :require_gem,
                -> { raise LoadError, "cannot load such file -- microsandbox" }) do
        error = assert_raises(Agent::Error) { Agent::Runtime::Microsandbox.load_gem }
        assert_kind_of StandardError, error,
          "LoadError is a ScriptError and would escape ChatJob's rescue"
        assert_match(/bundle install/, error.message)
      end
    end
  end

  test "the workspace quota knob widens the scope mount's write budget" do
    with_agent_config(microsandbox_workspace_quota_mib: 16_384) do
      with_sandbox_create(FakeSandbox.new) do |captured|
        with_pi_session(fake_session) do
          @runtime.run(pi_args: [ "--mode", "rpc" ]) { nil }
        end

        _name, params = captured.first
        assert_equal 16_384, params[:volumes]["/metis"][:quota_mib]
      end
    end
  end

  test "registry credentials ride create only when both are configured" do
    with_agent_config(microsandbox_registry_username: "ci-bot",
                      microsandbox_registry_password: "token") do
      with_sandbox_create(FakeSandbox.new) do |captured|
        with_pi_session(fake_session) do
          @runtime.run(pi_args: [ "--mode", "rpc" ]) { nil }
        end

        _name, params = captured.first
        assert_equal({ username: "ci-bot", password: "token" }, params[:registry_auth])
      end
    end

    with_agent_config(microsandbox_registry_username: "ci-bot",
                      microsandbox_registry_password: nil) do
      with_sandbox_create(FakeSandbox.new) do |captured|
        with_pi_session(fake_session) do
          @runtime.run(pi_args: [ "--mode", "rpc" ]) { nil }
        end

        _name, params = captured.first
        refute params.key?(:registry_auth)
      end
    end
  end

  test "runtime_info names the microsandbox runtime and its VM" do
    with_sandbox_create(FakeSandbox.new) do |_captured|
      with_pi_session(fake_session) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) { nil }
      end
    end

    info = @runtime.runtime_info
    assert_equal "microsandbox", info["runtime"]
    assert_match(/\Ametis-c#{@conversation.id}-/, info["sandbox"])
  end

  test "collects artifacts from the bind-mounted host workspace post-turn" do
    with_sandbox_create(FakeSandbox.new) do |_captured|
      with_pi_session(fake_session) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) do
          FileUtils.mkdir_p(@workspace.artifacts_dir)
          File.write(@workspace.artifacts_dir.join("chart.png"), "fakepng")
        end
      end
    end

    assert_equal [ "chart.png" ], @runtime.artifacts.map { |a| a[:filename] }
  end

  test "files the agent writes survive into the next turn via the persistent bind mount" do
    with_sandbox_create(FakeSandbox.new) do |_captured|
      with_pi_session(fake_session) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) { @workspace.workspace_dir.join("wip.txt").write("hello") }
      end
    end

    second_runtime = Agent::Runtime::Microsandbox.new(conversation: @conversation)
    with_sandbox_create(FakeSandbox.new) do |_captured|
      with_pi_session(fake_session) do
        second_runtime.run(pi_args: [ "--mode", "rpc" ]) do
          assert_equal "hello", @workspace.workspace_dir.join("wip.txt").read
        end
      end
    end
  end

  test "discards the staged mcp config at end of turn" do
    with_sandbox_create(FakeSandbox.new) do |_captured|
      with_pi_session(fake_session) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) do
          assert @workspace.workspace_dir.join(Agent::McpConfig::FILENAME).exist?,
            "mcp config staged for the turn"
        end
      end
    end

    refute @workspace.workspace_dir.join(Agent::McpConfig::FILENAME).exist?,
      "mcp config must not outlive the turn on the persistent host dir"
  end

  test "discards the staged mcp config even when the VM never boots" do
    with_stub(::Microsandbox::Sandbox, :create, ->(*, **) { raise ::Microsandbox::Error, "image pull failed" }) do
      with_pi_session(fake_session) do
        assert_raises(::Microsandbox::Error) do
          @runtime.run(pi_args: [ "--mode", "rpc" ]) { nil }
        end
      end
    end

    refute @workspace.workspace_dir.join(Agent::McpConfig::FILENAME).exist?,
      "the staged bearer tokens must not linger when provisioning fails"
  end

  test "control_session boots its throwaway VM on a RAM-backed root disk" do
    sandbox = FakeSandbox.new("metis-control-abcd")

    with_sandbox_create(sandbox) do |captured|
      with_pi_session(fake_session) do
        Agent::Runtime::Microsandbox.control_session { |_s| nil }
      end

      name, params = captured.first
      assert_match(/\Ametis-control-/, name)
      assert_equal({ "kind" => "tmpfs" }, params[:root_disk])
      assert_equal({ "app" => "metis" }, params[:labels])
    end

    assert sandbox.stopped?
  end

  FakeHandle = Struct.new(:name, :status)

  # Serve `pages` (arrays of FakeHandle) one per list_with call, chaining a
  # cursor between them, and record every call's kwargs.
  def with_listed_pages(pages)
    calls = []
    stub = lambda do |labels: {}, limit: nil, cursor: nil|
      calls << { labels: labels, limit: limit, cursor: cursor }
      index = cursor ? cursor.to_s.delete_prefix("page-").to_i : 0
      last = index >= pages.size - 1
      ::Microsandbox::SandboxPage.new(pages[index] || [], last ? nil : "page-#{index + 1}")
    end
    with_stub(::Microsandbox::Sandbox, :list_with, stub) { yield calls }
  end

  test "reaps a prior crashed turn's stale VM state before creating, sparing live ones" do
    handles = [
      FakeHandle.new("metis-c#{@conversation.id}-dead", :stopped),
      FakeHandle.new("metis-c#{@conversation.id}-crashed", :crashed),
      FakeHandle.new("metis-c#{@conversation.id}-live", :running),
      FakeHandle.new("metis-c#{@conversation.id}0-other", :stopped),
      FakeHandle.new("unrelated", :stopped)
    ]
    removed = []
    calls = nil
    with_listed_pages([ handles ]) do |listed|
      calls = listed
      with_stub(::Microsandbox::Sandbox, :remove, ->(name) { removed << name }) do
        with_sandbox_create(FakeSandbox.new) do |_captured|
          with_pi_session(fake_session) do
            @runtime.run(pi_args: [ "--mode", "rpc" ]) { nil }
          end
        end
      end
    end

    assert_equal [ "metis-c#{@conversation.id}-dead", "metis-c#{@conversation.id}-crashed" ],
      removed
    assert_equal({ "app" => "metis" }, calls.first[:labels],
      "the listing must be narrowed to metis's own VMs server-side")
  end

  test "the sweep follows the cursor past the first page" do
    conversation_id = @conversation.id
    pages = [
      [ FakeHandle.new("metis-c#{conversation_id}-live", :running),
        FakeHandle.new("unrelated", :stopped) ],
      [ FakeHandle.new("metis-c#{conversation_id}-dead", :stopped),
        FakeHandle.new("metis-c#{conversation_id}0-other", :stopped) ]
    ]
    removed = []
    calls = nil
    with_listed_pages(pages) do |listed|
      calls = listed
      with_stub(::Microsandbox::Sandbox, :remove, ->(name) { removed << name }) do
        with_sandbox_create(FakeSandbox.new) do |_captured|
          with_pi_session(fake_session) do
            @runtime.run(pi_args: [ "--mode", "rpc" ]) { nil }
          end
        end
      end
    end

    assert_equal [ "metis-c#{conversation_id}-dead" ], removed,
      "a stale VM on the second page must still be reaped"
    assert_equal 2, calls.size
    assert_nil calls.first[:cursor]
    assert_equal "page-1", calls.last[:cursor]
  end

  test "the sweep walks every page of a long healthy traversal" do
    conversation_id = @conversation.id
    # Well past the old 50-page cap, to prove coverage is not truncated.
    pages = Array.new(120) { [ FakeHandle.new("unrelated", :stopped) ] }
    pages[119] = [ FakeHandle.new("metis-c#{conversation_id}-dead", :stopped) ]
    removed = []
    calls = nil

    with_listed_pages(pages) do |listed|
      calls = listed
      with_stub(::Microsandbox::Sandbox, :remove, ->(name) { removed << name }) do
        with_sandbox_create(FakeSandbox.new) do |_captured|
          with_pi_session(fake_session) do
            @runtime.run(pi_args: [ "--mode", "rpc" ]) { nil }
          end
        end
      end
    end

    assert_equal [ "metis-c#{conversation_id}-dead" ], removed
    assert_equal 120, calls.size
  end

  test "the sweep breaks out when the server repeats a cursor" do
    pages = 0
    looping = lambda do |labels: {}, limit: nil, cursor: nil|
      pages += 1
      ::Microsandbox::SandboxPage.new([], "always-the-same")
    end

    with_stub(::Microsandbox::Sandbox, :list_with, looping) do
      with_sandbox_create(FakeSandbox.new) do |_captured|
        with_pi_session(fake_session) do
          @runtime.run(pi_args: [ "--mode", "rpc" ]) { nil }
        end
      end
    end

    assert_equal 2, pages,
      "a repeated cursor must end the walk, not run to the backstop"
  end

  test "endless unique cursors still terminate at the pathological backstop" do
    pages = 0
    endless = lambda do |labels: {}, limit: nil, cursor: nil|
      pages += 1
      ::Microsandbox::SandboxPage.new([], "cursor-#{pages}")
    end

    with_stub(::Microsandbox::Sandbox, :list_with, endless) do
      with_sandbox_create(FakeSandbox.new) do |_captured|
        with_pi_session(fake_session) do
          @runtime.run(pi_args: [ "--mode", "rpc" ]) { nil }
        end
      end
    end

    assert_equal Agent::Runtime::Microsandbox::REAP_PAGE_BACKSTOP, pages
  end
end
