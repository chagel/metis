require "json"
require "securerandom"
require "shellwords"

module Agent
  module Runtime
    # Transport that runs `pi --mode rpc` as a long-lived async command inside
    # a Daytona session and bridges its stdio. Implements pi-agent-rb's
    # transport contract (start / write / close / alive?), so PiAgent::Client
    # drives pi-in-a-Daytona-sandbox exactly as it drives a local subprocess.
    #
    # Daytona has no single "run a background command with a stdin pipe" call
    # like E2B's. Instead a *session* holds a long-running command:
    #   - execute_session_command(runAsync: true)  starts pi, returns a cmd id
    #   - send_session_command_input                writes one JSON-RPC line to stdin
    #   - get_session_command_logs_async            follows stdout/stderr (a
    #     blocking WebSocket stream), reframed through PiAgent::Framer
    # `suppressInputEcho: true` keeps our stdin writes out of the log stream, so
    # the JSONL framer never parses a request we sent as a response from pi.
    class DaytonaTransport
      include TransportTiming

      CLOSE_TIMEOUT = 5

      # `pi_command` is the pi command line as a String (Shellwords-joined);
      # cwd/envs are folded into the shell command because a Daytona session
      # command takes neither. `on_message`/`on_stderr` are pi-agent-rb's handlers.
      def initialize(sandbox:, pi_command:, cwd: nil, envs: {}, on_message: nil, on_stderr: nil)
        @sandbox = sandbox
        @pi_command = pi_command
        @cwd = cwd
        @envs = envs || {}
        @on_message = on_message
        @on_stderr = on_stderr
        @session_id = "metis-#{SecureRandom.hex(8)}"
        @write_mutex = Mutex.new
        @closed = false
        @finished = false
      end

      def start
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @sandbox.process.create_session(@session_id)
        response = @sandbox.process.execute_session_command(
          @session_id,
          { command: shell_command, runAsync: true, suppressInputEcho: true }
        )
        @command_id = response.cmd_id
        @reader = Thread.new { read_loop }
        self
      end

      def write(obj)
        payload = "#{JSON.generate(obj)}\n"
        @write_mutex.synchronize do
          raise PiAgent::ProtocolError, "Daytona transport closed" if @closed

          @sandbox.process.send_session_command_input(@session_id, @command_id, payload)
        end
      end

      def close(timeout: CLOSE_TIMEOUT)
        @write_mutex.synchronize do
          return if @closed

          @closed = true
        end
        delete_session
        @reader&.join(timeout)
      end

      def alive?
        !@closed && !@finished
      end

      private

      # A Daytona session command runs through a shell, so cwd and per-turn env
      # are expressed inline: `cd <ws> && KEY=v ... exec pi <args>`. `exec`
      # replaces the shell with pi so there is no intermediate process.
      def shell_command
        env_prefix = @envs.map { |k, v| "#{k}=#{Shellwords.escape(v.to_s)}" }.join(" ")
        run = [ env_prefix, "exec", @pi_command ].reject(&:empty?).join(" ")
        @cwd ? "cd #{Shellwords.escape(@cwd.to_s)} && #{run}" : run
      end

      def read_loop
        out_framer = PiAgent::Framer.new
        err_framer = PiAgent::Framer.new
        @sandbox.process.get_session_command_logs_async(
          @session_id, @command_id,
          on_stdout: ->(chunk) { out_framer.feed(chunk) { |line| dispatch_message(line) } },
          on_stderr: ->(chunk) { err_framer.feed(chunk) { |line| dispatch_stderr(line) } }
        )
      rescue StandardError => e
        # Once the reader stops, pi's responses can no longer arrive and every
        # pending RPC will hang to its timeout. Log loudly rather than dying as
        # a silent thread death.
        Rails.logger.error("[daytona] pi stdout reader stopped: #{e.class}: #{e.message}")
      ensure
        @finished = true
      end

      def dispatch_message(line)
        log_first_message
        @on_message&.call(JSON.parse(line))
      rescue JSON::ParserError => e
        Rails.logger.warn("[daytona] non-JSON line from pi: #{e.message}: #{line.inspect}")
      end

      # pi's stderr is otherwise invisible — the runtime is a remote sandbox
      # and pi-agent-rb's default stderr handler is a no-op.
      def dispatch_stderr(line)
        Rails.logger.warn("[daytona pi stderr] #{line}")
        @on_stderr&.call(line)
      end

      def delete_session
        @sandbox.process.delete_session(@session_id)
      rescue Daytona::DaytonaError
        # Session or sandbox already gone.
      end
    end
  end
end
