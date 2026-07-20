require "test_helper"

# The microsandbox-rb gem rides an optional bundler group and is absent in
# CI; the transport only touches the injected sandbox object, so a minimal
# stand-in for its error class keeps these tests gem-free.
unless defined?(Microsandbox)
  module Microsandbox
    class Error < StandardError; end
  end
end

class Agent::Runtime::MicrosandboxTransportTest < ActiveSupport::TestCase
  # Mirrors Microsandbox::ExecEvent's duck-type.
  FakeEvent = Struct.new(:type, :data, :code, keyword_init: true) do
    def stdout? = type == :stdout
    def stderr? = type == :stderr
    def exited? = type == :exited
    def failed? = type == :failed
    def stdin_error? = type == :stdin_error
    def text = data&.dup&.force_encoding(Encoding::UTF_8)
  end

  class FakeStdin
    attr_reader :writes

    def initialize
      @writes = []
      @closed = false
    end

    def write(data)
      @writes << data
      self
    end

    def close = (@closed = true)
    def closed? = @closed
  end

  # Fake Microsandbox::ExecHandle: replays canned events and exposes the
  # stdin sink.
  class FakeHandle
    attr_reader :stdin

    def initialize(events)
      @events = events
      @stdin = FakeStdin.new
      @killed = false
    end

    def each
      @events.each { |event| yield event }
    end

    def kill = (@killed = true)
    def killed? = @killed
  end

  class FakeSandbox
    attr_reader :exec_calls

    def initialize(handle)
      @handle = handle
      @exec_calls = []
    end

    def exec_stream(command, args = [], **kwargs)
      @exec_calls << { command: command, args: args, **kwargs }
      @handle
    end
  end

  def build_transport(events, on_message: nil, on_stderr: nil)
    handle = FakeHandle.new(events)
    sandbox = FakeSandbox.new(handle)
    transport = Agent::Runtime::MicrosandboxTransport.new(
      sandbox: sandbox, command: "pi", args: [ "--mode", "rpc" ],
      cwd: "/metis/workspace", on_message: on_message, on_stderr: on_stderr
    )
    [ transport, handle, sandbox ]
  end

  def stdout_event(data) = FakeEvent.new(type: :stdout, data: data)
  def stderr_event(data) = FakeEvent.new(type: :stderr, data: data)

  test "start execs pi with a stdin pipe in the workspace" do
    transport, _handle, sandbox = build_transport([])
    transport.start

    call = sandbox.exec_calls.first
    assert_equal "pi", call[:command]
    assert_equal [ "--mode", "rpc" ], call[:args]
    assert_equal "/metis/workspace", call[:cwd]
    assert_equal :pipe, call[:stdin]
  ensure
    transport&.close
  end

  test "parses JSON messages from stdout event chunks" do
    received = Queue.new
    transport, = build_transport(
      [ stdout_event(%({"type":"a"}\n)), stdout_event(%({"type":"b","x":1}\n)) ],
      on_message: ->(msg) { received << msg }
    )
    transport.start

    assert_equal({ "type" => "a" }, received.pop(timeout: 2))
    assert_equal({ "type" => "b", "x" => 1 }, received.pop(timeout: 2))
  ensure
    transport&.close
  end

  test "reframes a JSON message split across event chunks" do
    received = Queue.new
    transport, = build_transport(
      [ stdout_event(%({"type":)), stdout_event(%("split"}\n)) ],
      on_message: ->(msg) { received << msg }
    )
    transport.start

    assert_equal({ "type" => "split" }, received.pop(timeout: 2))
  ensure
    transport&.close
  end

  test "write sends a JSON line to the stdin sink" do
    transport, handle, = build_transport([])
    transport.start
    transport.write({ "x" => 1 })

    assert_equal [ %({"x":1}\n) ], handle.stdin.writes
  ensure
    transport&.close
  end

  test "write rejects a payload over the guest frame limit" do
    transport, handle, = build_transport([])
    transport.start

    oversized = { "data" => "x" * Agent::Runtime::MicrosandboxTransport::MAX_STDIN_FRAME_BYTES }
    assert_raises(PiAgent::ProtocolError) { transport.write(oversized) }
    assert_empty handle.stdin.writes, "an oversized frame must never reach the sink"
  ensure
    transport&.close
  end

  test "forwards stderr events as lines" do
    received = Queue.new
    transport, = build_transport(
      [ stderr_event("boom\n") ],
      on_stderr: ->(line) { received << line }
    )
    transport.start

    assert_equal "boom", received.pop(timeout: 2)
  ensure
    transport&.close
  end

  test "close sends EOF, kills the command, and rejects further writes" do
    transport, handle, = build_transport([])
    transport.start
    transport.close

    assert handle.killed?, "the guest process is killed first — it unblocks any parked native call"
    assert handle.stdin.closed?, "the stdin sink is released on close"
    assert_raises(PiAgent::ProtocolError) { transport.write({ "x" => 1 }) }
  end

  test "surfaces a spawn failure instead of dropping the event" do
    received = Queue.new
    transport, = build_transport(
      [ FakeEvent.new(type: :failed, data: "No such file or directory") ],
      on_stderr: ->(line) { received << line }
    )
    transport.start

    assert_match(/No such file or directory/, received.pop(timeout: 2))
  ensure
    transport&.close
  end

  test "surfaces a non-zero exit code, staying silent on a clean exit" do
    received = Queue.new
    transport, = build_transport(
      [ FakeEvent.new(type: :exited, code: 137) ],
      on_stderr: ->(line) { received << line }
    )
    transport.start
    assert_match(/exited with code 137/, received.pop(timeout: 2))
    transport.close

    clean = Queue.new
    quiet_transport, = build_transport(
      [ FakeEvent.new(type: :exited, code: 0) ],
      on_stderr: ->(line) { clean << line }
    )
    quiet_transport.start
    quiet_transport.close
    assert_empty clean
  ensure
    transport&.close
  end
end
