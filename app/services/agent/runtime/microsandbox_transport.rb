require "json"

module Agent
  module Runtime
    # Transport that runs `pi --mode rpc` inside a microsandbox libkrun
    # microVM and bridges its stdio. Implements pi-agent-rb's transport
    # contract (start / write / close / alive?), so PiAgent::Client drives
    # pi-in-a-microVM exactly as it drives a local subprocess.
    #
    # microsandbox's exec_stream is a direct execve (no shell) that returns a
    # streaming handle plus a writable stdin sink (`stdin: :pipe`). Stdout
    # arrives as byte-chunk events, not lines, so chunks are reframed through
    # PiAgent::Framer (strict-LF JSONL) before parsing. There is no exec-side
    # lifetime cap (the gem discards `timeout:` on the streaming path) — the
    # VM's max_duration is the wall-clock backstop (see Runtime::Microsandbox).
    class MicrosandboxTransport
      include TransportTiming

      CLOSE_TIMEOUT = 5
      # microsandbox's guest agent protocol rejects frames over 4 MiB, and one
      # stdin write becomes one frame. The rejection is not a clean typed
      # error at the write site, so pre-check here — the offending write
      # raises at its call site, with margin for the protocol envelope around
      # the payload.
      MAX_STDIN_FRAME_BYTES = 4 * 1024 * 1024 - 64 * 1024

      # `command`/`args` are pi's argv (exec_stream takes them separately — no
      # shell, no escaping). `on_message`/`on_stderr` are pi-agent-rb's
      # handlers. `envs` is per-turn projected credentials (see
      # Runtime::Base#sandbox_env) — passed per-exec so nothing lands in the
      # sandbox's stored config.
      def initialize(sandbox:, command:, args: [], cwd: nil, envs: {}, on_message: nil, on_stderr: nil)
        @sandbox = sandbox
        @command = command
        @args = args
        @cwd = cwd
        @envs = envs || {}
        @on_message = on_message
        # pi's stderr is otherwise invisible — the runtime is a microVM and
        # pi-agent-rb's default stderr handler is a no-op.
        @stderr_relay = Agent::Runtime.stderr_relay("microsandbox", on_stderr)
        @write_mutex = Mutex.new
        @closed = false
        @finished = false
      end

      def start
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @handle = @sandbox.exec_stream(
          @command, @args, cwd: @cwd&.to_s, env: @envs, stdin: :pipe
        )
        @stdin = @handle.stdin
        raise PiAgent::ProtocolError, "microsandbox exec_stream returned no stdin sink" if @stdin.nil?

        @reader = Thread.new { read_loop }
        self
      end

      # The native write BLOCKS until the guest accepts the frame; a wedged
      # guest parks the calling thread here, and only #close's kill_command
      # tears the stream down and unblocks it (Thread#kill can't interrupt a
      # native call). The mutex serializes concurrent writers so JSONL lines
      # can't interleave — #close must never need it (see below).
      def write(obj)
        payload = "#{JSON.generate(obj)}\n"
        if payload.bytesize > MAX_STDIN_FRAME_BYTES
          raise PiAgent::ProtocolError,
            "stdin write of #{payload.bytesize} bytes exceeds the microsandbox " \
            "frame limit (#{MAX_STDIN_FRAME_BYTES} bytes) — pi would never receive it"
        end

        @write_mutex.synchronize do
          raise PiAgent::ProtocolError, "microsandbox transport closed" if @closed

          @stdin.write(payload)
        end
      end

      # Kill FIRST, without taking @write_mutex: a writer parked in the
      # blocking native write holds that mutex, and the kill is the only
      # thing that unblocks it — acquiring the mutex before the kill would
      # deadlock the teardown behind the very hang it exists to break. A
      # racing write that slipped past the @closed flag fails loudly against
      # the killed stream instead of hanging.
      def close(timeout: CLOSE_TIMEOUT)
        return if @closed

        @closed = true
        kill_command
        close_stdin
        @reader&.join(timeout)
      end

      def alive?
        !@closed && !@finished
      end

      private

      # The reader parks in a native `each` (recv) that Thread#kill cannot
      # interrupt; #kill_command ending the guest process is what unblocks it.
      # Non-stdio events are pi's death certificate — a missing binary
      # (`:failed`, e.g. an image without pi on PATH) or an OOM kill
      # (`:exited` 137) would otherwise surface only as a later generic RPC
      # timeout with nothing in the logs.
      def read_loop
        out_framer = PiAgent::Framer.new
        err_framer = PiAgent::Framer.new
        @handle.each do |event|
          if event.stdout?
            out_framer.feed(event.data.to_s) { |line| dispatch_message(line) }
          elsif event.stderr?
            err_framer.feed(event.data.to_s) { |line| @stderr_relay.call(line) }
          elsif event.failed? || event.stdin_error?
            @stderr_relay.call("microsandbox exec failed: #{event.text || event.code}")
          elsif event.exited? && event.code.to_i.nonzero?
            @stderr_relay.call("pi exited with code #{event.code}")
          end
        end
      rescue StandardError => e
        # Once the reader stops, pi's responses can no longer arrive and every
        # pending RPC will hang to its timeout. Log loudly rather than dying
        # as a silent thread death.
        Rails.logger.error("[microsandbox] pi stdout reader stopped: #{e.class}: #{e.message}")
      ensure
        @finished = true
      end

      def dispatch_message(line)
        log_first_message
        @on_message&.call(JSON.parse(line))
      rescue JSON::ParserError => e
        Rails.logger.warn("[microsandbox] non-JSON line from pi: #{e.message}: #{line.inspect}")
      end

      def close_stdin
        @stdin&.close
      rescue StandardError
        # process already gone
      end

      def kill_command
        @handle&.kill
      rescue ::Microsandbox::Error
        # Command or sandbox already gone.
      end
    end
  end
end
