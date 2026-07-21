require "json"

module Agent
  module Runtime
    # Transport that runs `pi --mode rpc` as a background command inside an
    # E2B sandbox and bridges its stdio. Implements pi-agent-rb's transport
    # contract (start / write / close / alive?), so PiAgent::Client drives
    # pi-in-a-microVM exactly as it drives a local subprocess.
    #
    # E2B delivers stdout as arbitrary byte chunks, not lines, so chunks are
    # reframed through PiAgent::Framer (strict-LF JSONL) before parsing.
    class E2bTransport
      include TransportTiming

      CLOSE_TIMEOUT = 5
      # Lifetime cap for the pi process. The e2b SDK derives the stdout
      # stream's HTTP timeout from this, so it must comfortably exceed the
      # longest turn — otherwise a slow LLM call silently kills the stream.
      COMMAND_TIMEOUT = 3600

      # `command` is the full pi command line (a String — E2B runs it via
      # bash -lc). `on_message`/`on_stderr` are pi-agent-rb's handlers.
      # `envs` is per-turn projected credentials (see Runtime::Base#sandbox_env).
      def initialize(sandbox:, command:, cwd: nil, envs: {}, on_message: nil, on_stderr: nil)
        @sandbox = sandbox
        @command = command
        @cwd = cwd
        @envs = envs
        @on_message = on_message
        @stderr_relay = Agent::Runtime.stderr_relay("e2b", on_stderr)
        @write_mutex = Mutex.new
        @closed = false
        @finished = false
      end

      def start
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # stdin: true is mandatory — without it E2B never opens the pipe
        # and send_stdin is a silent no-op.
        @handle = @sandbox.commands.run(
          @command, background: true, stdin: true, cwd: @cwd&.to_s,
          envs: @envs, timeout: COMMAND_TIMEOUT
        )
        @reader = Thread.new { read_loop }
        self
      end

      def write(obj)
        payload = "#{JSON.generate(obj)}\n"
        @write_mutex.synchronize do
          raise PiAgent::ProtocolError, "E2B transport closed" if @closed

          @handle.send_stdin(payload)
        end
      end

      def close(timeout: CLOSE_TIMEOUT)
        @write_mutex.synchronize do
          return if @closed

          @closed = true
        end
        kill_command
        @reader&.join(timeout)
      end

      def alive?
        !@closed && !@finished
      end

      private

      def read_loop
        out_framer = PiAgent::Framer.new
        err_framer = PiAgent::Framer.new
        @handle.each do |stdout, stderr, _pty|
          out_framer.feed(stdout) { |line| dispatch_message(line) } if stdout
          err_framer.feed(stderr) { |line| dispatch_stderr(line) } if stderr
        end
      rescue StandardError => e
        # Once the reader stops, pi's responses can no longer arrive and
        # every pending RPC will hang to its timeout. Log loudly rather
        # than dying as a silent thread death.
        Rails.logger.error("[e2b] pi stdout reader stopped: #{e.class}: #{e.message}")
      ensure
        @finished = true
      end

      def dispatch_message(line)
        log_first_message
        @on_message&.call(JSON.parse(line))
      rescue JSON::ParserError => e
        Rails.logger.warn("[e2b] non-JSON line from pi: #{e.message}: #{line.inspect}")
      end

      def dispatch_stderr(line)
        @stderr_relay.call(line)
      end

      def kill_command
        @handle&.kill
      rescue E2B::E2BError
        # Command or sandbox already gone.
      end
    end
  end
end
