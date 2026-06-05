require "securerandom"

module Agent
  module Runtime
    # Runs pi inside a Docker container — the middle isolation tier.
    #
    # `docker run -i` wires the container's stdio to the docker client
    # process, so pi-in-a-container is driven through pi-agent-rb's plain
    # subprocess transport — no custom transport is needed (cf. E2b,
    # which bridges an HTTP API).
    #
    # The conversation's scope directory is a persistent host path
    # (Agent::Workspace.persistent) bind-mounted into the container, so
    # the working tree, `.git`, dependency installs, and untracked WIP
    # survive between turns naturally — no archive, no per-turn restore.
    # The container itself is still disposable: --rm wipes anything
    # outside the bind mount (system installs, $HOME) at end of turn.
    # See docs/coding-runtime.md.
    #
    # Isolation: namespace + cgroup confinement and dropped capabilities
    # — stronger than Local (pi cannot reach the host filesystem beyond
    # the mounts, or host processes), weaker than E2b (a shared kernel,
    # not a microVM). Suitable for trusted, self-hosted multi-user use.
    #
    # Assumes the worker has direct access to a Docker daemon and can
    # bind-mount host paths (not Docker-in-Docker). pi must be installed
    # in the image (config.x.agent.docker_image — see docker:image).
    # Multi-worker deployments need shared access to the persistent
    # workspace root (NFS or equivalent) or per-conversation host pinning
    # — same shared-state constraint Local has always had.
    class Docker < Base
      # The conversation scope, bind-mounted from the host Workspace.
      SCOPE_DIR = "/metis".freeze
      SESSION_DIR = "#{SCOPE_DIR}/sessions".freeze
      WORKSPACE_DIR = "#{SCOPE_DIR}/workspace".freeze
      # The app's pi extensions, bind-mounted read-only — code, not
      # session state, so kept out of the archived scope.
      EXTENSIONS_DIR = "/metis-extensions".freeze
      # Container hardening applied to every `docker run` we spawn (turn or
      # control query) — one list so the two paths can't drift.
      HARDENING_ARGS = %w[--cap-drop ALL --security-opt no-new-privileges].freeze

      # Forward env values into the container by bare key (--env NAME), so
      # docker reads them from the client process's own env rather than
      # placing secrets in argv where `ps` could see them.
      def self.env_forward(env)
        env.keys.flat_map { |name| [ "--env", name ] }
      end

      # Control-plane session (Agent::Runtime.control_session): the image's
      # pi answers, so no bind mount or workspace — a throwaway
      # `docker run --rm <image> pi --mode rpc`. Provider keys in `env` are
      # forwarded by bare-key `--env NAME` (read from the docker client's
      # own env) so they stay out of argv.
      def self.control_session(env: {})
        args = [
          "run", "--rm", "-i", "--pull", "never",
          "--env", "HOME=/tmp",
          *env_forward(env),
          "--memory", "512m", "--cpus", "1", "--pids-limit", "256",
          *HARDENING_ARGS,
          Rails.application.config.x.agent.docker_image,
          "pi", "--mode", "rpc"
        ]
        session = PiAgent.session(bin: "docker", args: args, env: env)
        yield session
      ensure
        session&.close
      end

      def session_dir
        Pathname.new(SESSION_DIR)
      end

      # Every turn runs a fresh container.
      def initial_status
        "Starting container"
      end

      # The app's pi extensions at their in-container paths, under the
      # read-only extensions mount (#docker_args bind-mounts the dir).
      def extension_paths
        Agent::Runtime.extension_sources.map do |source|
          Pathname.new("#{EXTENSIONS_DIR}/#{source.parent.basename}/#{source.basename}")
        end
      end

      def run(pi_args:)
        workspace.ensure!
        workspace.stage_uploads(conversation.uploaded_files)
        workspace.stage_mcp_config(mcp_config)
        workspace.stage_identity(identity_content)
        workspace.stage_skills
        turn_started_at = Time.current.floor  # see Local#run
        env = sandbox_env
        emit_status(:starting, "Starting container")
        session = PiAgent.session(bin: "docker", args: docker_args(pi_args, env: env), env: env)
        begin
          yield session
        ensure
          collect_host_artifacts(dir: workspace.artifacts_dir, since: turn_started_at)
          ingest_team_skills(slugs: touched_skill_slugs)
          session.close
          remove_container
          workspace.discard_mcp_config
        end
      end

      # Container writes land on the bind-mounted host workspace; the
      # host-side ingest reads them in place. Logged-not-raised.
      def ingest_team_skills(slugs:)
        workspace.ingest_team_skills(slugs: slugs, by: conversation.user)
        workspace.queue_skill_imports(by: conversation.user)
      rescue StandardError => e
        Rails.logger.warn("ingest_team_skills failed for conversation #{conversation.id}: #{e.message}")
      end

      # Adds the container name, so a turn can be traced even though the
      # container is removed after the run.
      def runtime_info
        super.merge("container" => container_name)
      end

      private

      def workspace
        @workspace ||= Agent::Workspace.persistent(conversation)
      end

      def container_name
        @container_name ||= "metis-c#{conversation.id}-#{SecureRandom.hex(4)}"
      end

      # `docker run` flags wrapping `pi <pi_args>`. The container runs as
      # the host uid so files on the bind mount stay owned by this
      # process (which archives them); capabilities are dropped and
      # resources capped. --pull never: the image is built locally.
      #
      # Credentials in `env` are forwarded with the bare-key `--env NAME`
      # form so docker reads the value from the parent process's env
      # (set on the spawned `docker` client via PiAgent.session(env:))
      # — keeping bearer tokens out of argv where `ps` could see them.
      def docker_args(pi_args, env: {})
        [
          "run", "--rm", "-i",
          "--pull", "never",
          "--name", container_name,
          "--user", "#{Process.uid}:#{Process.gid}",
          "--volume", "#{workspace.scope_dir}:#{SCOPE_DIR}",
          *extension_mount,
          "--workdir", WORKSPACE_DIR,
          "--env", "HOME=/tmp",
          *self.class.env_forward(env),
          "--memory", "2g", "--cpus", "2", "--pids-limit", "512",
          *HARDENING_ARGS,
          image,
          "pi", *pi_args
        ]
      end

      def extension_mount
        return [] if Agent::Runtime.extension_sources.empty?

        [ "--volume", "#{Rails.root.join('.pi/extensions')}:#{EXTENSIONS_DIR}:ro" ]
      end

      # Force-remove the container — a net for when the docker client was
      # killed before --rm could fire (e.g. an aborted turn). Best effort.
      def remove_container
        system("docker", "rm", "--force", container_name, out: File::NULL, err: File::NULL)
      end

      def image
        Rails.application.config.x.agent.docker_image
      end
    end
  end
end
