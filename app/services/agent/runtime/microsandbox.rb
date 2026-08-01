require "securerandom"

module Agent
  module Runtime
    # Runs pi inside a self-hosted microsandbox libkrun microVM, driven
    # in-process by the microsandbox-rb gem — no daemon, no cloud API.
    # VM-grade isolation (its own guest kernel) at self-hosted cost: the
    # E2b/Daytona isolation tier without leaving the box, on Linux with KVM
    # or macOS on Apple Silicon.
    #
    # Persistence follows Docker, not E2b/Daytona: the VM is disposable —
    # created fresh each turn (`ephemeral: true`, so its stored state is
    # reaped on stop) — and the conversation's scope directory is a
    # persistent host path (Agent::Workspace.persistent) bind-mounted into
    # the guest. The working tree, `.git`, pi's session transcript, and
    # untracked WIP survive between turns on the host filesystem; there is
    # no sandbox to pause, resume, or evict. Because the VM runs in-process,
    # a dead worker takes its VMs with it — no orphan reaper needed.
    #
    # Staging is host-side (the bind mount projects it into the guest), so
    # per-turn inputs cost filesystem writes, not upload RPCs. The app's pi
    # extensions ride a second, read-only bind mount — the runtime is
    # embedded in the worker, so host paths resolve without the
    # Docker-in-Docker indirection that makes Runtime::Docker bake them
    # into its image.
    #
    # pi must be present in the OCI image (config.x.agent.microsandbox_image).
    # The docker:image build satisfies the contract, but microsandbox pulls
    # from OCI registries — it cannot see a local Docker daemon's store — so
    # push the image somewhere the worker can pull it from. Build it for the
    # *worker's* arch: libkrun boots the guest on the host CPU, so unlike the
    # hosted runtimes (which build on the provider's fleet) a mismatch here
    # fails the same way Runtime::Docker's does.
    #
    # The gem rides an optional bundler group (see Gemfile) because it
    # compiles a Rust native extension; it is lazily required here so every
    # other runtime boots without it.
    class Microsandbox < Base
      # The conversation scope, bind-mounted from the host Workspace.
      SCOPE_DIR = "/metis".freeze
      SESSION_DIR = "#{SCOPE_DIR}/sessions".freeze
      WORKSPACE_DIR = "#{SCOPE_DIR}/workspace".freeze
      # The app's pi extensions, bind-mounted read-only from the repo.
      EXTENSIONS_DIR = "/metis-extensions".freeze
      EXTENSIONS_SOURCE = Rails.root.join(".pi/extensions").freeze
      CPUS = 2
      MEMORY_MIB = 2048
      # Hard wall-clock cap on the VM, and the ONLY lifetime enforcement a
      # turn has — the gem discards exec-side timeouts on the streaming path,
      # so there is no shorter cap on pi itself. Must exceed the longest turn.
      MAX_DURATION = 7200
      CONTROL_PREFIX = "metis-control-".freeze
      # Sweep-eligible states — :starting/:running belong to a live
      # concurrent use.
      TERMINAL_STATES = %i[stopped crashed].freeze
      # Stamped on every VM so the sweep's listing filters server-side.
      LABELS = { "app" => "metis" }.freeze
      # Pathological backstop only — a server that never reports a last
      # page (looping or endless cursors). It is not a coverage bound: a
      # healthy traversal runs to last_page? long before this.
      REAP_PAGE_BACKSTOP = 1000

      def self.image
        Rails.application.config.x.agent.microsandbox_image
      end

      # Optional registry credentials for pulling the image (private
      # registries, or lifting Docker Hub's anonymous rate limit). Without
      # them the gem still honors an existing `docker login`
      # (~/.docker/config.json).
      def self.registry_auth
        agent = Rails.application.config.x.agent
        return nil unless agent.microsandbox_registry_username.present? &&
                          agent.microsandbox_registry_password.present?

        { username: agent.microsandbox_registry_username,
          password: agent.microsandbox_registry_password }
      end

      def self.create_params
        { image: image, ephemeral: true, labels: LABELS,
          registry_auth: registry_auth }.compact
      end

      # The gem rides an optional bundler group (it compiles a Rust native
      # extension); loaded on first use so every other runtime boots without
      # it. Tests stand in a minimal ::Microsandbox, which the guard honors.
      #
      # LoadError is a ScriptError, not a StandardError, so a deployment that
      # selected this runtime without installing the group would sail past
      # ChatJob's rescue and strand the turn's assistant message in
      # `streaming` until the stale-turn sweep. Translate it.
      def self.load_gem
        return if gem_loaded?

        require_gem
      rescue LoadError => e
        raise Agent::Error,
          "the :microsandbox runtime needs the optional microsandbox-rb gem — run " \
          "`bundle config set --local with microsandbox && bundle install` on this " \
          "host, or pick another METIS_AGENT_RUNTIME (#{e.message})"
      end

      # Seams: the test stand-in defines ::Microsandbox for the whole process,
      # so the require path is only reachable with these two stubbed.
      def self.gem_loaded? = !!defined?(::Microsandbox)

      def self.require_gem = require("microsandbox")

      # `ephemeral` cleanup is runtime-driven, so a SIGKILLed worker leaves
      # the dead VM's stored state (its overlay upper dir) on disk with
      # nothing to reclaim it — a slow leak that has filled a root disk
      # elsewhere. Names are unique per turn (or per control query) under a
      # known prefix, so anything not running is a leftover; sweeping before
      # each create makes the next use self-healing without a reaper cron.
      # Logged-not-raised.
      #
      # The listing is cursor-paginated (gem 0.11+ / runtime v0.6.8) and yields
      # one page at a time, so a single `list` would silently under-reap on a
      # busy host. LABELS narrows the pages to metis's own VMs server-side;
      # `prefix` stays the local reap boundary. Removals are held until the
      # walk finishes — mutating the set mid-walk can invalidate the cursor.
      #
      # The walk runs to last_page? so coverage is never truncated;
      # REAP_PAGE_BACKSTOP only bounds a server that never reports one.
      def self.reap_stale_sandboxes(prefix)
        stale = []
        cursor = nil
        REAP_PAGE_BACKSTOP.times do
          page = ::Microsandbox::Sandbox.list_with(labels: LABELS, limit: 100, cursor: cursor)
          page.each do |handle|
            next unless handle.name.start_with?(prefix) && TERMINAL_STATES.include?(handle.status)

            stale << handle.name
          end
          break if page.last_page?

          cursor = page.next_cursor
        end
        stale.uniq.each { |name| ::Microsandbox::Sandbox.remove(name) }
      rescue ::Microsandbox::Error => e
        Rails.logger.warn("microsandbox stale-state sweep failed (#{prefix}*): #{e.message}")
      end

      # Control-plane session (Agent::Runtime.control_session): the image's
      # pi answers, so no bind mounts or workspace — an ephemeral throwaway
      # VM, asked and stopped. `env` carries the deployment's provider keys
      # so pi advertises them. Its writable layer is RAM-backed (tmpfs, half
      # the VM's memory by default), so a SIGKILLed worker leaves no overlay
      # upper dir behind for the sweep to find in the first place.
      def self.control_session(env: {})
        load_gem
        reap_stale_sandboxes(CONTROL_PREFIX)
        sandbox = ::Microsandbox::Sandbox.create(
          "#{CONTROL_PREFIX}#{SecureRandom.hex(4)}",
          cpus: 1, memory: 512, max_duration: 600,
          root_disk: ::Microsandbox::RootDisk.tmpfs, **create_params
        )
        factory = lambda do |on_message:, on_stderr:|
          MicrosandboxTransport.new(
            sandbox: sandbox, command: "pi", args: %w[--mode rpc], envs: env,
            on_message: on_message, on_stderr: on_stderr
          )
        end
        session = PiAgent.session(transport_factory: factory)
        yield session
      ensure
        session&.close
        stop_or_kill(sandbox, context: "control_session") if sandbox
      end

      # A failed `stop` leaves the VM running — holding its full CPU/memory
      # reservation until MAX_DURATION, and invisible to the sweep, which
      # only reaps terminal states — so escalate to SIGKILL instead of just
      # logging. Logged-not-raised throughout: teardown must not crash a turn
      # the user already saw stream.
      def self.stop_or_kill(sandbox, context:)
        sandbox.stop
      rescue ::Microsandbox::Error => e
        Rails.logger.warn("microsandbox stop failed (#{context}): #{e.message} — force-killing")
        begin
          sandbox.kill
        rescue ::Microsandbox::Error => kill_error
          Rails.logger.warn("microsandbox kill failed (#{context}): #{kill_error.message}")
        end
      end

      def session_dir
        Pathname.new(SESSION_DIR)
      end

      # Every turn boots a fresh VM.
      def initial_status
        "Starting microVM"
      end

      # The extensions bind mount preserves the repo layout, so each
      # extension keeps its <name>/index.ts path.
      def extension_paths
        Agent::Runtime.extension_sources.map do |source|
          Pathname.new("#{EXTENSIONS_DIR}/#{source.parent.basename}/#{source.basename}")
        end
      end

      def run(pi_args:, extension_ui: nil)
        init_timings
        # Detect a warm-evicted workspace before ensure! recreates the dir —
        # same detection as Docker: the persistent root is shared across the
        # host runtimes, so a conversation evicted under :docker and
        # continued here must still get the lost-files warning.
        @workspace_evicted = conversation.backend_session_id.present? && !workspace.workspace_dir.directory?
        workspace.ensure!
        turn_started_at = Time.current.floor  # see Local#run
        begin
          # Staging inside the begin so the ensure's mcp discard covers a
          # failure mid-staging, not just a failed boot.
          timed(:staging) do
            workspace.stage_uploads(conversation.uploaded_files)
            workspace.stage_mcp_config(mcp_config)
            workspace.stage_identity(identity_content)
            workspace.stage_skills
          end
          emit_status(:starting, "Starting microVM")
          sandbox = timed(:create) { create_sandbox }
          session = PiAgent.session(
            transport_factory: transport_factory(sandbox, pi_args, sandbox_env),
            extension_ui: extension_ui
          )
          timed(:pi_session) { yield session }
        ensure
          # The VM goes down first — artifact collection and skill ingest
          # read the bind-mounted host dir and don't need it running.
          session&.close
          stop_sandbox(sandbox) if sandbox
          if session
            timed(:collect_artifacts) do
              collect_host_artifacts(dir: workspace.artifacts_dir, since: turn_started_at)
            end
            timed(:ingest_team_skills) { ingest_team_skills(slugs: touched_skill_slugs) }
          end
          # Even when the VM never booted — the staged .mcp.json carries live
          # bearer tokens and must not linger on the persistent host dir.
          workspace.discard_mcp_config
          log_timings
        end
      end

      # Guest writes land on the bind-mounted host workspace; the host-side
      # ingest reads them in place. Logged-not-raised.
      def ingest_team_skills(slugs:)
        workspace.ingest_team_skills(slugs: slugs, by: conversation.user)
        workspace.queue_skill_imports(by: conversation.user)
      rescue StandardError => e
        Rails.logger.warn("ingest_team_skills failed for conversation #{conversation.id}: #{e.message}")
      end

      # Adds the VM name, so a turn can be traced even though the VM is
      # stopped (and its stored state reaped) after the run.
      def runtime_info
        super.merge("sandbox" => @sandbox_name)
      end

      def workspace_evicted? = !!@workspace_evicted

      private

      def workspace
        @workspace ||= Agent::Workspace.persistent(conversation)
      end

      # The prefix is the reap boundary — sandbox_name must stay under it.
      def sandbox_prefix = "metis-c#{conversation.id}-"

      def sandbox_name
        @sandbox_name ||= "#{sandbox_prefix}#{SecureRandom.hex(4)}"
      end

      # Attached (the default) on purpose: an attached VM dies with the
      # process that created it, so a killed worker can't leak a running
      # microVM. Its *stored state* can still outlive the crash — see
      # #reap_stale_sandboxes.
      def create_sandbox
        self.class.load_gem
        self.class.reap_stale_sandboxes(sandbox_prefix)
        ::Microsandbox::Sandbox.create(
          sandbox_name,
          cpus: CPUS, memory: MEMORY_MIB, workdir: WORKSPACE_DIR,
          volumes: volumes, max_duration: MAX_DURATION,
          **self.class.create_params
        )
      end

      # The scope mount is the persistence boundary; everything else the VM
      # writes is overlay, gone at stop. quota_mib lifts the runtime's
      # default guest-write budget on the mount when a deployment's working
      # trees outgrow it.
      def volumes
        scope = { bind: workspace.scope_dir.to_s,
                  quota_mib: Rails.application.config.x.agent.microsandbox_workspace_quota_mib }.compact
        mounts = { SCOPE_DIR => scope }
        mounts[EXTENSIONS_DIR] = { bind: EXTENSIONS_SOURCE.to_s, ro: true } if EXTENSIONS_SOURCE.directory?
        mounts
      end

      # `stop` escalates SIGTERM → SIGKILL itself, and `ephemeral: true`
      # reaps the stored state once stopped.
      def stop_sandbox(sandbox)
        self.class.stop_or_kill(sandbox, context: "conversation #{conversation.id}")
      end

      def transport_factory(sandbox, pi_args, envs)
        lambda do |on_message:, on_stderr:|
          MicrosandboxTransport.new(
            sandbox: sandbox, command: "pi", args: pi_args, cwd: WORKSPACE_DIR,
            envs: envs, on_message: on_message, on_stderr: on_stderr
          )
        end
      end
    end
  end
end
