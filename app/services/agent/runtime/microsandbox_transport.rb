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
      # Watchdog on the blocking native stdin write (see #write). Generous —
      # well past pi's own 30s RPC ack timeout, so it only fires on a truly
      # wedged guest, converting an unbounded worker hang into a failed turn.
      WRITE_TIMEOUT = 60
      # microsandbox's guest agent protocol rejects frames over 4 MiB, and one
      # stdin write becomes one frame. The rejection is not a clean typed
      # error at the write site, so pre-check here — the offending write
      # raises at its call site, with margin for the protocol envelope around
      # the payload.
      MAX_STDIN_FRAME_BYTES = 4 * 1024 * 1024 - 64 * 1024

      # `command`/`args` are pi's argv (exec_stream takes them separately — no
      # shell, no escaping). `on_message`/`on_stderr`/`on_close` are
      # pi-agent-rb's handlers — `on_close` is the 0.3.0 death notification,
      # fired once when the stream ends without `#close` being called (see
      # read_loop). `envs` is per-turn projected credentials (see
      # Runtime::Base#sandbox_env) — passed per-exec so nothing lands in the
      # sandbox's stored config.
      def initialize(sandbox:, command:, args: [], cwd: nil, envs: {}, on_message: nil, on_stderr: nil,
                     on_close: nil, write_timeout: WRITE_TIMEOUT)
        @sandbox = sandbox
        @command = command
        @args = args
        @cwd = cwd
        @envs = envs || {}
        @write_timeout = write_timeout
        @on_message = on_message
        @on_close = on_close
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

      # The native write BLOCKS until the guest accepts the frame, and
      # Thread#kill can't interrupt a native call — so the write runs on a
      # helper thread the caller joins with a deadline. A wedged guest now
      # parks only the disposable helper: on deadline the stream is killed
      # (the one thing that unblocks a parked native write) and the caller
      # fails loudly instead of pinning a worker until the VM's max_duration.
      # The mutex serializes concurrent writers so JSONL lines can't
      # interleave — #close must never need it (see below).
      def write(obj)
        payload = "#{JSON.generate(obj)}\n"
        if payload.bytesize > MAX_STDIN_FRAME_BYTES
          raise PiAgent::ProtocolError,
            "stdin write of #{payload.bytesize} bytes exceeds the microsandbox " \
            "frame limit (#{MAX_STDIN_FRAME_BYTES} bytes) — pi would never receive it"
        end

        @write_mutex.synchronize do
          raise PiAgent::ProtocolError, "microsandbox transport closed" if @closed

          writer = Thread.new do
            Thread.current.report_on_exception = false
            @stdin.write(payload)
          end
          next if writer.join(@write_timeout)

          @closed = true
          kill_command
          # A watchdog kill is a transport-side death, not an owner #close:
          # report it so pending RPCs and event streams fail now. @closed is
          # already set, so the reader's own notification stays silent —
          # exactly-once holds.
          reason = "stdin write not accepted within #{@write_timeout}s — guest wedged, stream killed"
          @on_close&.call(reason)
          raise PiAgent::ProtocolError, reason
        end
      end

      # Kill FIRST, without taking @write_mutex: a write caller can hold that
      # mutex for up to @write_timeout while its helper is parked in the
      # blocking native write, and the kill is the only thing that unblocks
      # the helper — acquiring the mutex before the kill would deadlock the
      # teardown behind the very hang it exists to break. A racing write that
      # slipped past the @closed flag fails loudly against the killed stream
      # instead of hanging.
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
      # (`:exited` 137) — and become the on_close reason, so the client fails
      # pending RPCs and event streams immediately instead of waiting out its
      # generic timeouts. The stream ending is terminal either way: buffered
      # stdout has been dispatched by then, and a close the owner initiated
      # (@closed) is expected, not a death.
      def read_loop
        reason = "pi stdout stream ended"
        out_framer = PiAgent::Framer.new
        err_framer = PiAgent::Framer.new
        @handle.each do |event|
          if event.stdout?
            out_framer.feed(event.data.to_s) { |line| dispatch_message(line) }
          elsif event.stderr?
            err_framer.feed(event.data.to_s) { |line| @stderr_relay.call(line) }
          elsif event.failed? || event.stdin_error?
            reason = "microsandbox exec failed: #{event.text || event.code}"
            @stderr_relay.call(reason)
          elsif event.exited?
            reason = "pi exited with code #{event.code}"
            @stderr_relay.call(reason) if event.code.to_i.nonzero?
          end
        end
      rescue StandardError => e
        # Once the reader stops, pi's responses can no longer arrive. Log
        # loudly rather than dying as a silent thread death.
        reason = "pi stdout reader stopped: #{e.class}: #{e.message}"
        Rails.logger.error("[microsandbox] #{reason}")
      ensure
        @finished = true
        @on_close&.call(reason) unless @closed
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
