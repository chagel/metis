require "test_helper"

class Agent::Runtime::DaytonaTransportTest < ActiveSupport::TestCase
  CmdResponse = Struct.new(:cmd_id)

  # Fake Daytona Process: records session lifecycle + stdin, and replays
  # canned stdout/stderr chunks through the follow-logs callbacks (already
  # demuxed, as the SDK delivers them).
  class FakeProcess
    attr_reader :inputs, :created_sessions, :deleted_sessions, :exec_calls

    def initialize(stdout: [], stderr: [])
      @stdout = stdout
      @stderr = stderr
      @inputs = []
      @created_sessions = []
      @deleted_sessions = []
      @exec_calls = []
    end

    def create_session(session_id)
      @created_sessions << session_id
    end

    def execute_session_command(session_id, request, **)
      @exec_calls << [ session_id, request ]
      CmdResponse.new("cmd-1")
    end

    def send_session_command_input(_session_id, _command_id, data)
      @inputs << data
    end

    def get_session_command_logs_async(_session_id, _command_id, on_stdout:, on_stderr:)
      @stdout.each { |chunk| on_stdout.call(chunk) }
      @stderr.each { |chunk| on_stderr.call(chunk) }
    end

    def delete_session(session_id)
      @deleted_sessions << session_id
    end
  end

  class FakeSandbox
    attr_reader :process

    def initialize(process)
      @process = process
    end
  end

  def build_transport(stdout: [], stderr: [], on_message: nil, on_stderr: nil)
    process = FakeProcess.new(stdout: stdout, stderr: stderr)
    transport = Agent::Runtime::DaytonaTransport.new(
      sandbox: FakeSandbox.new(process), pi_command: "pi --mode rpc", cwd: "/root/metis/workspace",
      on_message: on_message, on_stderr: on_stderr
    )
    [ transport, process ]
  end

  test "parses JSON messages from stdout chunks" do
    received = Queue.new
    transport, = build_transport(
      stdout: [ %({"type":"a"}\n), %({"type":"b","x":1}\n) ],
      on_message: ->(msg) { received << msg }
    )
    transport.start

    assert_equal({ "type" => "a" }, received.pop(timeout: 2))
    assert_equal({ "type" => "b", "x" => 1 }, received.pop(timeout: 2))
  ensure
    transport&.close
  end

  test "reframes a JSON message split across chunks" do
    received = Queue.new
    transport, = build_transport(
      stdout: [ %({"type":), %("split"}\n) ],
      on_message: ->(msg) { received << msg }
    )
    transport.start

    assert_equal({ "type" => "split" }, received.pop(timeout: 2))
  ensure
    transport&.close
  end

  test "write sends a JSON line to the session command's stdin" do
    transport, process = build_transport
    transport.start
    transport.write({ "x" => 1 })

    assert_equal [ %({"x":1}\n) ], process.inputs
  ensure
    transport&.close
  end

  test "forwards stderr chunks as lines" do
    received = Queue.new
    transport, = build_transport(stderr: [ "boom\n" ], on_stderr: ->(line) { received << line })
    transport.start

    assert_equal "boom", received.pop(timeout: 2)
  ensure
    transport&.close
  end

  test "starts an async session command that suppresses input echo and execs pi in cwd" do
    transport, process = build_transport
    transport.start

    assert_equal 1, process.created_sessions.size
    _session_id, request = process.exec_calls.first
    assert request[:runAsync], "command runs async so it stays alive for stdin"
    assert request[:suppressInputEcho], "stdin writes must not echo into the log stream"
    assert_includes request[:command], "cd /root/metis/workspace"
    assert_includes request[:command], "exec pi --mode rpc"
  ensure
    transport&.close
  end

  test "close deletes the session and rejects further writes" do
    transport, process = build_transport
    transport.start
    transport.close

    assert_equal 1, process.deleted_sessions.size
    assert_raises(PiAgent::ProtocolError) { transport.write({ "x" => 1 }) }
  end
end
