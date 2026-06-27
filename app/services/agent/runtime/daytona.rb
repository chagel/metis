require "open3"
require "shellwords"
require "time"

module Agent
  module Runtime
    # Runs pi inside a Daytona elastic sandbox — an isolated runtime, the
    # Daytona analog of Runtime::E2b.
    #
    # The sandbox lives across turns: the first turn creates it, later turns
    # resume it by id. Daytona persists a *stopped* sandbox's filesystem on its
    # runner, so the conversation's working tree, session transcript, installed
    # dependencies, and untracked WIP survive between turns by being the same
    # sandbox. "Pause" maps to `stop`, "resume" to `start` (see
    # docs/session-persistence.md).
    #
    # Unlike E2B, where a suspended sandbox is free, Daytona still bills a
    # *stopped* sandbox for disk storage — so the sandbox is stopped after a
    # keep-warm window (#schedule_stop enqueues DaytonaStopJob, off the request
    # path) to end compute billing, and create sets autoArchive/autoDelete to
    # move a long-idle sandbox to cheap object storage and then reap it. There
    # is no eviction cron; that ladder is Daytona's job.
    #
    # This IS an isolation boundary: pi's shell is confined to the sandbox.
    # The sandbox id is recorded on the Conversation so any worker can resume
    # the same sandbox (worker fungibility — the state lives in addressable
    # remote storage, not in a worker process).
    #
    # pi must be present in the snapshot image (config.x.agent.daytona_snapshot
    # — a snapshot with pi baked in; see the daytona:snapshot rake task).
    class Daytona < Base
      SCOPE_DIR = "/root/metis".freeze
      SESSION_DIR = "#{SCOPE_DIR}/sessions".freeze
      WORKSPACE_DIR = "#{SCOPE_DIR}/workspace".freeze
      ARTIFACTS_DIR = "#{WORKSPACE_DIR}/#{Agent::Workspace::ARTIFACTS_SUBPATH}".freeze
      # Outside SCOPE_DIR on purpose — extensions are code shipped from this
      # app, restaged each turn rather than relied on to persist via stop/start
      # (so a pi-extensions update reaches an existing conversation next turn).
      EXTENSIONS_DIR = "/root/pi-extensions".freeze
      # Repo .pi/skills/ baked into the snapshot image by the daytona:snapshot
      # rake task. #stage_skills copies this into the workspace on fresh
      # sandboxes, dodging the per-file upload that .pi/skills/'s 300+ files
      # would cost over the wire.
      BAKED_REPO_SKILLS_DIR = "/opt/metis/repo-skills".freeze
      # Sandboxes run as root so build-time `pi install` (root's ~/.pi) and
      # run-time discovery agree; SCOPE_DIR follows.
      OS_USER = "root".freeze
      SANDBOX_TIMEOUT = 600

      # Shared client — auth is a deployment-level resource.
      def self.client
        @client ||= ::Daytona::Client.new(
          ::Daytona::Configuration.new(
            api_key: Rails.application.config.x.agent.daytona_api_key,
            api_url: Rails.application.config.x.agent.daytona_api_url,
            target: Rails.application.config.x.agent.daytona_target
          )
        )
      end

      # Delete a sandbox by id, swallowing the not-found case. Used by
      # Conversation#before_destroy and any caller holding a stored id but no
      # live Sandbox handle.
      def self.kill_sandbox(sandbox_id)
        return if sandbox_id.blank?

        client.get(sandbox_id).delete
      rescue ::Daytona::NotFoundError
        # already gone — same outcome we wanted
      rescue ::Daytona::DaytonaError => e
        Rails.logger.warn("Daytona sandbox delete failed for sandbox_id=#{sandbox_id}: #{e.message}")
      end

      # Seconds a conversation's sandbox stays running after a turn before the
      # deferred stop ends its compute billing.
      def self.keep_warm_seconds
        Rails.application.config.x.agent.daytona_keep_warm_seconds.to_i
      end

      # Stop the sandbox to end compute billing while keeping its filesystem for
      # the next resume. Called out-of-band by DaytonaStopJob after the
      # keep-warm window. Logged-not-raised: on failure the box is deleted so it
      # can't leak as a running orphan, and the id is cleared so the next turn
      # provisions fresh.
      def self.stop_sandbox(conversation, sandbox_id)
        client.get(sandbox_id).stop(timeout: SANDBOX_TIMEOUT)
      rescue ::Daytona::NotFoundError
        conversation.update_column(:daytona_sandbox_id, nil)
      rescue ::Daytona::DaytonaError => e
        Rails.logger.warn("Daytona deferred stop failed for conversation #{conversation.id}: #{e.message}")
        kill_sandbox(sandbox_id)
        conversation.update_column(:daytona_sandbox_id, nil)
      end

      def session_dir
        Pathname.new(SESSION_DIR)
      end

      # A stored sandbox id means the next turn resumes (or restores from
      # archive — indistinguishable without a network call, so predict the
      # common case); otherwise it creates fresh.
      def initial_status
        conversation.daytona_sandbox_id.present? ? "Resuming sandbox" : "Creating sandbox"
      end

      # Control-plane session (Agent::Runtime.control_session): the snapshot's
      # pi answers. There is no persistent sandbox for a control query, so spin
      # an ephemeral one, ask, and delete it. `env` carries the deployment's
      # provider keys so pi advertises them.
      def self.control_session(env: {})
        sandbox = client.create(
          ::Daytona::Models::CreateSandboxFromSnapshotParams.new(
            snapshot: Rails.application.config.x.agent.daytona_snapshot, os_user: OS_USER
          ),
          timeout: SANDBOX_TIMEOUT
        )
        command = Shellwords.join(%w[pi --mode rpc])
        factory = lambda do |on_message:, on_stderr:|
          DaytonaTransport.new(
            sandbox: sandbox, pi_command: command, envs: env,
            on_message: on_message, on_stderr: on_stderr
          )
        end
        session = PiAgent.session(transport_factory: factory)
        yield session
      ensure
        session&.close
        begin
          sandbox&.delete
        rescue ::Daytona::DaytonaError => e
          Rails.logger.warn("Daytona control_session cleanup failed: #{e.message}")
        end
      end

      # The app's pi extensions at their planned in-sandbox paths. Deterministic
      # so pi_args can be built before the sandbox exists; #stage_extensions
      # uploads the files to them.
      def extension_paths
        Agent::Runtime.extension_sources.map { |source| Pathname.new(sandbox_extension_path(source)) }
      end

      def run(pi_args:, extension_ui: nil, &block)
        init_timings
        sandbox = timed(:acquire) { acquire_sandbox }
        @sandbox_id = sandbox.id
        turn_started_at = Time.current.floor  # see Local#run
        execute(sandbox, pi_args: pi_args, extension_ui: extension_ui, &block)
      ensure
        if sandbox
          timed(:collect_artifacts) { collect_sandbox_artifacts(sandbox, since: turn_started_at) } if turn_started_at
          timed(:ingest_team_skills) { ingest_team_skills(sandbox: sandbox, slugs: touched_skill_slugs) }
          timed(:discard_mcp) { discard_mcp_config(sandbox) }
          timed(:schedule_stop) { schedule_stop(sandbox) }
        end
        log_timings
      end

      # Pull each touched skill out of the sandbox and upsert it. Runs while the
      # sandbox is still up (before #schedule_stop hands it to the stop job).
      # Logged-not-raised.
      def ingest_team_skills(sandbox:, slugs:)
        repo_slugs = Agent::Workspace.repo_slugs
        slugs.each do |slug|
          next if repo_slugs.include?(slug)
          next unless Skill::SLUG_FORMAT.match?(slug)

          files = read_sandbox_skill_files(sandbox, slug)
          next if files.empty?

          workspace.ingest_team_skill_from_files(slug: slug, files: files, by: conversation.user)
        end

        queue_skill_imports(sandbox: sandbox)
      rescue StandardError => e
        Rails.logger.warn("ingest_team_skills failed for conversation #{conversation.id}: #{e.message}")
      end

      def queue_skill_imports(sandbox:)
        path = "#{WORKSPACE_DIR}/#{Agent::Workspace::SKILLS_SUBPATH}/#{Agent::Workspace::SKILL_IMPORTS_FILE}"
        return unless file_exists?(sandbox, path)

        Agent::Workspace.enqueue_imports(
          body: download_text(sandbox, path),
          team_id: conversation.team_id,
          by_user_id: conversation.user_id
        )
      rescue StandardError => e
        Rails.logger.warn("queue_skill_imports failed for conversation #{conversation.id}: #{e.message}")
      end

      # Adds the sandbox's id, so a turn can be traced to its sandbox in
      # Daytona's dashboard.
      def runtime_info
        super.merge("sandbox_id" => @sandbox_id)
      end

      private

      def execute(sandbox, pi_args:, extension_ui: nil)
        emit_status(:preparing, "Preparing workspace")
        timed(:provision) { provision(sandbox) }
        # Individual stage_* timings below overlap (they run concurrently);
        # :staging is the wall-clock that actually counts.
        timed(:staging) { stage_projected_inputs(sandbox) }
        session = PiAgent.session(transport_factory: transport_factory(sandbox, pi_args, sandbox_env), extension_ui: extension_ui)
        begin
          timed(:pi_session) { yield session }
        ensure
          session.close
        end
      end

      # Resume the conversation's stopped sandbox, or create one if there isn't
      # a usable one. A stored id that no longer resolves (Daytona-side cleanup,
      # eviction, manual delete) is cleared and we fall back to fresh provision.
      def acquire_sandbox
        if conversation.daytona_sandbox_id.present?
          resume_existing
        else
          create_fresh
        end
      end

      def resume_existing
        sandbox = self.class.client.get(conversation.daytona_sandbox_id)
        unless sandbox.state == "started"
          # Starting an archived sandbox restores its filesystem from object
          # storage (slower) — surface that as a distinct phase.
          if sandbox.state == "archived"
            emit_status(:restoring, "Restoring sandbox")
          else
            emit_status(:resuming, "Resuming sandbox")
          end
          sandbox.start(timeout: SANDBOX_TIMEOUT)
        end
        @sandbox_was_resumed = true
        sandbox
      rescue ::Daytona::NotFoundError
        Rails.logger.info(
          "Daytona sandbox #{conversation.daytona_sandbox_id} not found for conversation " \
          "#{conversation.id}; provisioning fresh"
        )
        conversation.update_column(:daytona_sandbox_id, nil)
        create_fresh
      end

      def create_fresh
        emit_status(:creating, "Creating sandbox")
        @sandbox_was_resumed = false
        self.class.client.create(
          ::Daytona::Models::CreateSandboxFromSnapshotParams.new(
            snapshot: snapshot,
            os_user: OS_USER,
            auto_stop_interval: config_minutes(:daytona_auto_stop_minutes),
            auto_archive_interval: config_minutes(:daytona_auto_archive_minutes),
            auto_delete_interval: config_minutes(:daytona_auto_delete_minutes)
          ),
          timeout: SANDBOX_TIMEOUT
        )
      end

      # Hand the sandbox off to a deferred stop rather than stopping inline. The
      # turn already streamed, so the stop (pure cost-control) must not hold the
      # worker or serialize with the next turn's resume. Persist the id now — a
      # follow-up, possibly inside the keep-warm window, needs it — then enqueue
      # the stop for keep_warm_seconds later. A follow-up within the window
      # reuses the still-running box and the job no-ops (see DaytonaStopJob); the
      # latest message id is the freshness token any new turn bumps.
      # Logged-not-raised.
      def schedule_stop(sandbox)
        if conversation.daytona_sandbox_id != sandbox.id
          conversation.update_column(:daytona_sandbox_id, sandbox.id)
        end

        DaytonaStopJob
          .set(wait: self.class.keep_warm_seconds.seconds)
          .perform_later(conversation.id, sandbox.id, conversation.messages.maximum(:id))
      rescue StandardError => e
        Rails.logger.warn("Daytona schedule_stop failed for conversation #{conversation.id}: #{e.message}")
      end

      def provision(sandbox)
        sandbox.process.exec("mkdir -p #{SESSION_DIR} #{WORKSPACE_DIR}/uploads")
      end

      # Copy the baked repo .pi/skills/ tree from the snapshot image into the
      # conversation workspace. One sandbox-local cp instead of ~300 per-file
      # uploads. Caller (#stage_skills) gates this on the baked dir existing and
      # on a fresh sandbox (the tree persists via stop/start on a resumed one).
      def stage_repo_skills_from_snapshot(sandbox)
        dest = "#{WORKSPACE_DIR}/#{Agent::Workspace::SKILLS_SUBPATH}"
        sandbox.process.exec(
          "rm -rf #{Shellwords.escape(dest)} && " \
          "mkdir -p #{Shellwords.escape(File.dirname(dest))} && " \
          "cp -r #{Shellwords.escape(BAKED_REPO_SKILLS_DIR)} #{Shellwords.escape(dest)}"
        )
      end

      # Upload the app's pi extensions so `pi --extension` can load them.
      # Re-staged each turn even on a resumed sandbox so an update to a bundled
      # extension reaches in-flight conversations.
      def stage_extensions(sandbox)
        sources = Agent::Runtime.extension_sources
        return if sources.empty?

        sandbox.process.exec("mkdir -p #{EXTENSIONS_DIR}")
        sources.each do |source|
          put_file(sandbox, sandbox_extension_path(source), File.binread(source))
        end
      end

      # An extension's path inside the sandbox. Each extension is a
      # <name>/index.ts; the upload is named <name>.ts so distinct extensions
      # do not collide on the shared index.ts basename.
      def sandbox_extension_path(source)
        "#{EXTENSIONS_DIR}/#{source.parent.basename}.ts"
      end

      # Read every file under WORKSPACE_DIR/.pi/skills/<slug>/ into an in-memory
      # map keyed by relative path. Skill dirs are small, so the cost is bounded.
      def read_sandbox_skill_files(sandbox, slug)
        root = "#{WORKSPACE_DIR}/#{Agent::Workspace::SKILLS_SUBPATH}/#{slug}"
        return {} unless file_exists?(sandbox, root)

        files = {}
        list_sandbox_files(sandbox, root).each do |entry|
          rel = entry[:path].delete_prefix("#{root}/")
          files[rel] = download_bytes(sandbox, entry[:path])
        end
        files
      end

      def workspace
        @workspace ||= Agent::Workspace.persistent(conversation)
      end

      # Project the conversation's uploaded files into uploads/. Filenames are
      # basenamed so a crafted name cannot escape the uploads dir.
      def stage_uploads(sandbox)
        conversation.uploaded_files.each do |attachment|
          name = File.basename(attachment.filename.to_s)
          next if name.blank? || [ ".", ".." ].include?(name)

          put_file(sandbox, "#{WORKSPACE_DIR}/uploads/#{name}", attachment.download)
        end
      end

      def stage_mcp_config(sandbox)
        put_file(sandbox, "#{WORKSPACE_DIR}/#{Agent::McpConfig::FILENAME}", mcp_config)
      end

      # Delete .mcp.json at end of turn so neither the keep-warm running sandbox
      # nor its persisted filesystem holds the live bearer tokens it carries.
      # Re-staged next turn. Logged-not-raised.
      def discard_mcp_config(sandbox)
        path = "#{WORKSPACE_DIR}/#{Agent::McpConfig::FILENAME}"
        sandbox.process.exec("rm -f #{Shellwords.escape(path)}")
      rescue StandardError => e
        Rails.logger.warn("Daytona mcp config cleanup failed for conversation #{conversation.id}: #{e.message}")
      end

      def stage_identity(sandbox)
        put_file(sandbox, "#{WORKSPACE_DIR}/#{Agent::Identity::FILENAME}", identity_content)
      end

      # Project skills into WORKSPACE_DIR/.pi/skills/. Repo skills come from the
      # baked snapshot dir (one cp on a fresh sandbox; trusted to persist on a
      # resumed one). Team skills are re-staged every turn — few in number and
      # may change between turns via the operator UI or agent authoring.
      def stage_skills(sandbox)
        dest_root = "#{WORKSPACE_DIR}/#{Agent::Workspace::SKILLS_SUBPATH}"

        unless @sandbox_was_resumed
          timed(:skills_repo) do
            if file_exists?(sandbox, BAKED_REPO_SKILLS_DIR)
              stage_repo_skills_from_snapshot(sandbox)
            else
              sandbox.process.exec("rm -rf #{Shellwords.escape(dest_root)}")
              stage_repo_skills_from_host(sandbox, dest_root)
            end
          end
        end

        timed(:skills_team) { stage_team_skills(sandbox, dest_root) }
      end

      # Ship the repo .pi/skills/ tree as one gzipped tar (built on the host)
      # and untar it in the sandbox — one upload + one extract instead of an
      # upload RPC per file, which for .pi/skills/'s 300+ files cost ~2 min over
      # the wire. COPYFILE_DISABLE keeps macOS ._ AppleDouble files out of the tar.
      def stage_repo_skills_from_host(sandbox, dest_root)
        source = Agent::Workspace::SKILLS_SOURCE
        return unless source.directory?

        archive, err, status = Open3.capture3(
          { "COPYFILE_DISABLE" => "1" }, "tar", "-czf", "-", "-C", source.to_s, "."
        )
        raise "tar of #{source} failed: #{err}" unless status.success?

        remote = "/tmp/metis-repo-skills.tgz"
        put_file(sandbox, remote, archive)
        sandbox.process.exec(
          "mkdir -p #{Shellwords.escape(dest_root)} && " \
          "tar -xzf #{remote} -C #{Shellwords.escape(dest_root)} && rm -f #{remote}"
        )
      end

      TEAM_SKILLS_MARKER = ".team-skills.sig".freeze

      def stage_team_skills(sandbox, dest_root)
        signature = Skill.team_signature(conversation.team)
        marker_path = "#{dest_root}/#{TEAM_SKILLS_MARKER}"

        if @sandbox_was_resumed && file_exists?(sandbox, marker_path)
          return if download_text(sandbox, marker_path) == signature
        end

        enabled = conversation.team.skills.enabled.to_a

        # Pruning stale dirs and clearing each slug dir before re-writing only
        # matters on a resumed sandbox — a fresh one's skills dir was just
        # created, so there is nothing stale; skip those round trips on fresh.
        if @sandbox_was_resumed && file_exists?(sandbox, dest_root)
          repo_slugs = Agent::Workspace.repo_slugs
          enabled_slugs = enabled.map(&:slug).to_set
          sandbox.fs.list_files(dest_root).each do |entry|
            next unless entry_dir?(entry)

            slug = entry_name(entry)
            next if slug.blank? || repo_slugs.include?(slug) || enabled_slugs.include?(slug)

            sandbox.process.exec("rm -rf #{Shellwords.escape("#{dest_root}/#{slug}")}")
          end
        end

        enabled.each do |skill|
          slug_dir = "#{dest_root}/#{skill.slug}"
          sandbox.process.exec("rm -rf #{Shellwords.escape(slug_dir)}") if @sandbox_was_resumed
          skill.files.each do |file|
            rel = Pathname.new(skill.relative_path(file)).cleanpath.to_s
            next if rel.start_with?("..") || rel.start_with?("/")

            put_file(sandbox, "#{slug_dir}/#{rel}", file.download)
          end
        end

        # Stamp last — a mid-stage failure leaves a stale signature, next turn reapplies.
        put_file(sandbox, marker_path, signature)
      end

      # Runs while the sandbox is still up (before #schedule_stop hands it to
      # the stop job) — a stopped sandbox's toolbox is unreachable.
      def collect_sandbox_artifacts(sandbox, since:)
        return unless file_exists?(sandbox, ARTIFACTS_DIR)

        list_sandbox_files(sandbox, ARTIFACTS_DIR).each do |entry|
          next if entry[:mod_time] && entry[:mod_time] < since

          if entry[:size] && entry[:size] > MAX_ARTIFACT_BYTES
            Rails.logger.warn("Skipping oversized artifact #{entry[:path]} (#{entry[:size]} bytes)")
            next
          end

          bytes = download_bytes(sandbox, entry[:path])
          rel = entry[:path].delete_prefix("#{ARTIFACTS_DIR}/")
          @artifacts << { filename: rel, io: StringIO.new(bytes) }
        end
      rescue StandardError => e
        Rails.logger.warn("Daytona artifact collection failed for conversation #{conversation.id}: #{e.message}")
      end

      # Recursively list files under `root`, returning hashes of
      # { path:, size:, mod_time: }. Daytona's list entries carry only a name
      # (no path), so paths are composed from the parent dir.
      def list_sandbox_files(sandbox, root)
        files = []
        stack = [ root ]
        until stack.empty?
          dir = stack.pop
          entries(sandbox, dir).each do |entry|
            name = entry_name(entry)
            next if name.blank?

            path = "#{dir}/#{name}"
            if entry_dir?(entry)
              stack << path
            else
              files << { path: path, size: entry_size(entry), mod_time: entry_mtime(entry) }
            end
          end
        end
        files
      end

      def entries(sandbox, dir)
        sandbox.fs.list_files(dir)
      rescue ::Daytona::NotFoundError
        []
      end

      # list_files entries are JSON.parse'd toolbox responses: string keys,
      # camelCase (name/isDir/size/modTime).
      def entry_name(entry) = entry["name"]
      def entry_dir?(entry) = entry["isDir"] || false
      def entry_size(entry) = entry["size"]

      def entry_mtime(entry)
        raw = entry["modTime"]
        raw && Time.parse(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      # Daytona's toolbox upload does not pre-create parent dirs the way E2B's
      # files.write does — write_file is given the full path and the daemon
      # creates intermediate dirs, but team-skill/extension writes go a level
      # deep, so the cp/mkdir staging above keeps that bounded.
      def put_file(sandbox, path, content)
        sandbox.fs.write_file(path, content)
      end

      def download_bytes(sandbox, path)
        sandbox.fs.download_file(path).to_s.dup.force_encoding(Encoding::BINARY)
      end

      def download_text(sandbox, path)
        sandbox.fs.download_file(path).to_s
      end

      # Any Daytona error (NotFoundError included) means "treat as absent" —
      # a transient probe failure should fall back to re-staging, not crash.
      def file_exists?(sandbox, path)
        sandbox.fs.get_file_info(path)
        true
      rescue ::Daytona::DaytonaError
        false
      end

      def transport_factory(sandbox, pi_args, envs)
        command = Shellwords.join([ "pi", *pi_args ])
        lambda do |on_message:, on_stderr:|
          DaytonaTransport.new(
            sandbox: sandbox, pi_command: command, cwd: WORKSPACE_DIR, envs: envs,
            on_message: on_message, on_stderr: on_stderr
          )
        end
      end

      def config_minutes(key)
        value = Rails.application.config.x.agent.public_send(key)
        value&.to_i
      end

      def snapshot
        Rails.application.config.x.agent.daytona_snapshot
      end
    end
  end
end
