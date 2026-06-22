module Agent
  module Runtime
    # Interface every runtime implements. A runtime decides where the
    # agent process physically runs and how its filesystem persists.
    class Base
      # Each artifact is held in memory at least once during attach;
      # drop oversized files rather than OOM the worker.
      MAX_ARTIFACT_BYTES = 10.megabytes

      attr_reader :conversation

      def initialize(conversation:)
        @conversation = conversation
        @artifacts = []
        @touched_skill_slugs = Set.new
      end

      # A proc the adapter sets so the runtime can report provisioning phases
      # (create/resume/restore/start/prepare) to the UI *before* the pi session
      # yields its first event. Called with (phase, message). Nil for control
      # sessions and tests, where #emit_status is a silent no-op.
      attr_accessor :status_sink

      # Report a provisioning phase. Failure-safe: a status broadcast must
      # never crash a turn the user is waiting on.
      def emit_status(phase, message)
        status_sink&.call(phase, message)
      rescue StandardError => e
        Rails.logger.warn("emit_status failed for conversation #{conversation.id}: #{e.message}")
      end

      # Files published during the most recent #run. Each entry is
      # { filename:, io: }, ready to pass to ActiveStorage#attach.
      attr_reader :artifacts

      # Directory the agent should pass to `pi --session-dir`.
      def session_dir
        raise NotImplementedError, "#{self.class} must implement #session_dir"
      end

      # The provisioning phase a turn is *likely* to open with, rendered into
      # the indicator's initial HTML so the first phase shows even though the
      # matching #emit_status broadcast races the indicator's own (HTTP)
      # render and is usually dropped. No network — a cheap prediction from
      # sandbox-id presence that later broadcasts refine. nil = no phase
      # (Local). See app/views/messages/_streaming_indicator and ChatBroadcaster.
      def initial_status
        nil
      end

      # Paths to the app's pi extensions (Agent::Runtime.extension_sources)
      # as reachable from this runtime's execution environment, for the Pi
      # adapter to load with `pi --extension`. A runtime that runs pi where
      # the repo files are absent must make them reachable and return those
      # paths. Default: none.
      def extension_paths
        []
      end

      # Slugs the agent's tools touched this turn — fed by Agent::Adapters::Pi.
      # Each runtime drains this in its own ingest_team_skills implementation.
      attr_reader :touched_skill_slugs

      def note_skill_touched(slug)
        @touched_skill_slugs << slug if slug.present?
      end

      # The rendered `.mcp.json` (Agent::McpConfig) for this
      # conversation's connectors, for a runtime to stage into pi's
      # workspace each turn.
      def mcp_config
        Agent::McpConfig.new(conversation).content
      end

      # The rendered AGENTS.md (Agent::Identity) — pi's per-turn boot file.
      # With no live transcript — a reaped sandbox or a cloud-source fork — it
      # also replays the conversation from the DB.
      def identity_content
        restore = context_lost? || conversation.needs_history_replay?
        Agent::Identity.new(conversation, kind, restore_history: restore).content
      end

      # The runtime's short name (`local`, `docker`, `e2b`) — used in
      # the agent identity file and the runtime_info trace.
      def kind
        self.class.name.demodulize.underscore
      end

      # Provision the runtime, open a PiAgent::Session running pi with
      # `pi_args`, yield it to the caller, then finalize (persist state,
      # tear down). The session is closed by the runtime, not the caller.
      #
      # The runtime also projects the conversation's uploaded files
      # (Conversation#uploaded_files) into pi's workspace/uploads/ — a
      # filesystem operation each runtime does its own way.
      def run(pi_args:)
        raise NotImplementedError, "#{self.class} must implement #run"
      end

      # A record of where the turn ran, persisted on the Conversation:
      # the runtime name, plus whatever per-run detail a subclass adds.
      def runtime_info
        { "runtime" => kind }
      end

      # Per-turn phase timing, shared across runtimes. A runtime calls
      # #init_timings at the top of #run, wraps each phase in #timed, and calls
      # #log_timings in its ensure. Output is one greppable line:
      #   [<kind> timing] conversation=N resumed=BOOL acquire=…ms staging=…ms …
      # #timed is thread-safe so staging phases can time themselves from worker
      # threads.
      def init_timings
        @timings = {}
        @timings_mutex = Mutex.new
      end

      def timed(phase)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        @timings_mutex.synchronize { @timings[phase] = ms }
      end

      def log_timings
        return if @timings.blank?

        summary = @timings.map { |phase, ms| "#{phase}=#{ms}ms" }.join(" ")
        Rails.logger.info(
          "[#{kind} timing] conversation=#{conversation.id} resumed=#{@sandbox_was_resumed} #{summary}"
        )
      end

      # label => method for the per-turn projected inputs, shared by the
      # sandbox runtimes (E2b, Daytona — same method names). #provision, which
      # creates the scope dirs these write under, runs first and separately.
      PARALLEL_STAGES = {
        stage_extensions: :stage_extensions,
        stage_uploads: :stage_uploads,
        stage_mcp: :stage_mcp_config,
        stage_identity: :stage_identity,
        stage_skills: :stage_skills
      }.freeze

      # Stage the projected inputs concurrently — wall-clock becomes the slowest
      # single step instead of their sum. Safe because they write to disjoint
      # paths and each runtime's SDK tolerates concurrent calls (Daytona pools
      # connections per thread; E2b verified). Each thread runs under the Rails
      # executor so its Active Record connection is returned promptly and
      # autoloading is thread-safe. A failure in any step is re-raised after all
      # join, so staging still fails the turn.
      def stage_projected_inputs(sandbox)
        errors = Thread::Queue.new
        PARALLEL_STAGES.map do |label, method|
          Thread.new do
            Rails.application.executor.wrap { timed(label) { send(method, sandbox) } }
          rescue StandardError => e
            errors << e
          end
        end.each(&:join)
        raise errors.pop unless errors.empty?
      end

      # Per-turn process environment to expose to the agent inside the
      # sandbox — credentials projected from the operator's OauthGrants.
      # Each entry is conditional on the operator having authorised the
      # underlying grant; nothing here is stored and nothing reaches disk.
      # See docs/connectors.md ("Credential pass-through to the sandbox").
      #
      # Today: GitHub and Google. The agent gets `GH_TOKEN` (consumed by
      # `git` and `gh`) plus a git author/committer identity so commits
      # carry the operator's handle rather than an anonymous default; and
      # `GOOGLE_WORKSPACE_CLI_TOKEN` (consumed by the `gws` CLI shipped in
      # the runtime image and driven by the gws-* skills) so Gmail /
      # Calendar / Drive calls act as the operator. `gws` also needs
      # `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` so it doesn't try to
      # talk to a desktop keyring in the headless sandbox.
      def sandbox_env
        env = {}
        github = bearer_or_nil(provider: "github", required_scopes: %w[repo])
        if github
          env["GH_TOKEN"] = github
          author = git_identity_for(conversation.user)
          env["GIT_AUTHOR_NAME"]     = author[:name]
          env["GIT_AUTHOR_EMAIL"]    = author[:email]
          env["GIT_COMMITTER_NAME"]  = author[:name]
          env["GIT_COMMITTER_EMAIL"] = author[:email]
        end

        google = bearer_or_nil(provider: "google")
        if google
          env["GOOGLE_WORKSPACE_CLI_TOKEN"] = google
          env["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"] = "file"
        end

        # Deployment-level web-search config consumed by the web-tools
        # extension's web_search tool. Not per-user — a shared backend for
        # reliable search from the sandbox (DuckDuckGo rate-limits datacenter
        # IPs). See config/initializers/agent.rb.
        agent = Rails.application.config.x.agent
        env["SERPER_API_KEY"] = agent.serper_api_key if agent.serper_api_key.present?
        env["BRAVE_SEARCH_API_KEY"] = agent.brave_search_api_key if agent.brave_search_api_key.present?
        env["SEARXNG_URL"] = agent.searxng_url if agent.searxng_url.present?

        env
      end

      protected

      # A stale/revoked grant for one provider must not crash the turn —
      # drop that credential and proceed, same as Agent::McpConfig does
      # when a connector's refresh fails.
      def bearer_or_nil(provider:, required_scopes: [])
        OauthBroker.bearer_for(
          user: conversation.user, provider: provider, required_scopes: required_scopes
        )
      rescue OauthBroker::Error => error
        Rails.logger.error(
          "sandbox_env: OAuth refresh failed for user=#{conversation.user_id} " \
          "provider=#{provider}: #{error.message} — omitting credential"
        )
        nil
      end

      # mtime-windowed so cleanup of artifacts/ stays the runtime's
      # job — old turns' files fall outside the window.
      def collect_host_artifacts(dir:, since:)
        return unless dir.directory?

        Dir.glob(dir.join("**/*"), File::FNM_DOTMATCH).each do |path|
          next if File.directory?(path)
          next unless File.mtime(path) >= since

          size = File.size(path)
          if size > MAX_ARTIFACT_BYTES
            Rails.logger.warn("Skipping oversized artifact #{path} (#{size} bytes)")
            next
          end

          rel = Pathname.new(path).relative_path_from(dir).to_s
          @artifacts << { filename: rel, io: File.open(path, "rb") }
        end
      rescue StandardError => e
        Rails.logger.warn("Artifact collection failed for conversation #{conversation.id}: #{e.message}")
      end

      private

      # A fresh sandbox for a conversation that already had a pi session: the
      # sandbox holding pi's transcript was reaped. Local/Docker never set the
      # flag (their workspace persists on the host), so this stays false there.
      def context_lost?
        @sandbox_was_resumed == false && conversation.backend_session_id.present?
      end

      def git_identity_for(user)
        email = user.email.to_s
        local = email.split("@", 2).first.presence || "metis-user"
        { name: local, email: email }
      end
    end
  end
end
