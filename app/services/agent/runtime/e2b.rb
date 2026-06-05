require "shellwords"
require "digest"

module Agent
  module Runtime
    # Runs pi inside an E2B secure microVM — the isolated runtime.
    #
    # The microVM lives across turns: first turn creates it, subsequent
    # turns resume from the paused snapshot E2B keeps server-side. The
    # conversation's working tree, session transcript, installed
    # dependencies, and untracked WIP persist between turns by being
    # *the same VM*. See docs/coding-runtime.md.
    #
    # This IS an isolation boundary: pi's shell is confined to the
    # microVM — the host, Metis's secrets, and other conversations are
    # unreachable. The sandbox_id is recorded on the Conversation so
    # any worker can resume the same VM (worker fungibility — the state
    # lives in addressable remote storage, not in a worker process).
    #
    # Eviction is metis's responsibility: E2B does not auto-clean paused
    # sandboxes. EvictPausedSandboxesJob kills VMs whose conversation
    # has been idle past config.x.agent.e2b_eviction_window; the next
    # turn provisions a fresh one and the working tree is gone.
    #
    # pi must be present in the sandbox image (config.x.agent.e2b_template
    # — a template with pi baked in; see the e2b:template rake task).
    class E2b < Base
      SCOPE_DIR = "/home/user/metis".freeze
      SESSION_DIR = "#{SCOPE_DIR}/sessions".freeze
      WORKSPACE_DIR = "#{SCOPE_DIR}/workspace".freeze
      ARTIFACTS_DIR = "#{WORKSPACE_DIR}/#{Agent::Workspace::ARTIFACTS_SUBPATH}".freeze
      # Outside SCOPE_DIR on purpose — extensions are code shipped from
      # this app, restaged each turn rather than relied on to persist
      # via pause/resume (so a pi-extensions update reaches an existing
      # conversation on the next turn).
      EXTENSIONS_DIR = "/home/user/pi-extensions".freeze
      # Repo .pi/skills/ baked into the template image by the e2b:template
      # rake task. #provision copies this into the workspace on fresh
      # sandboxes, dodging the per-file upload that .pi/skills/'s 300+
      # files used to cost (~60s over the wire).
      BAKED_REPO_SKILLS_DIR = "/opt/metis/repo-skills".freeze
      SANDBOX_TIMEOUT = 600

      # Kill a paused sandbox by id, swallowing the not-found case.
      # Used by Conversation#before_destroy and the eviction job —
      # places that hold a stored id but no live Sandbox handle.
      def self.kill_sandbox(sandbox_id)
        return if sandbox_id.blank?

        E2B::Sandbox.kill(sandbox_id)
      rescue E2B::NotFoundError
        # already gone — same outcome we wanted
      rescue E2B::E2BError => e
        Rails.logger.warn("E2B sandbox kill failed for sandbox_id=#{sandbox_id}: #{e.message}")
      end

      def session_dir
        Pathname.new(SESSION_DIR)
      end

      # A stored sandbox id means the next turn resumes; otherwise it creates.
      def initial_status
        conversation.e2b_sandbox_id.present? ? "Resuming sandbox" : "Creating sandbox"
      end

      # Control-plane session (Agent::Runtime.control_session): the
      # template's pi answers. There is no persistent sandbox for a control
      # query, so spin an ephemeral microVM, ask, and kill it — heavier
      # than Local/Docker (the catalog is baked into the template, so
      # capturing it at e2b:template build time is the optimization if this
      # refresh cost ever matters). `env` carries the deployment's provider
      # keys so pi advertises them.
      def self.control_session(env: {})
        sandbox = E2B::Sandbox.create(
          template: Rails.application.config.x.agent.e2b_template, timeout: SANDBOX_TIMEOUT
        )
        command = Shellwords.join(%w[pi --mode rpc])
        factory = lambda do |on_message:, on_stderr:|
          E2bTransport.new(
            sandbox: sandbox, command: command, envs: env,
            on_message: on_message, on_stderr: on_stderr
          )
        end
        session = PiAgent.session(transport_factory: factory)
        yield session
      ensure
        session&.close
        sandbox&.kill
      end

      # The app's pi extensions at their planned in-sandbox paths. These
      # are deterministic so pi_args can be built before the sandbox
      # exists; #stage_extensions uploads the files to them.
      def extension_paths
        Agent::Runtime.extension_sources.map { |source| Pathname.new(sandbox_extension_path(source)) }
      end

      def run(pi_args:, &block)
        init_timings
        sandbox = timed(:acquire) { acquire_sandbox }
        @sandbox_id = sandbox.sandbox_id
        turn_started_at = Time.current.floor  # see Local#run
        execute(sandbox, pi_args: pi_args, &block)
      ensure
        if sandbox
          timed(:collect_artifacts) { collect_sandbox_artifacts(sandbox, since: turn_started_at) } if turn_started_at
          timed(:ingest_team_skills) { ingest_team_skills(sandbox: sandbox, slugs: touched_skill_slugs) }
          timed(:discard_mcp) { discard_mcp_config(sandbox) }
          timed(:pause) { pause_sandbox(sandbox) }
        end
        log_timings
      end

      # Pull each touched skill out of the sandbox and upsert it. The
      # adapter already filtered to .pi/skills/<slug>/ paths, so we
      # know exactly which dirs to read — no listing of the whole
      # tree, no mtime gate. Must run before #pause_sandbox: a paused
      # sandbox's filesystem is unreachable. Logged-not-raised.
      def ingest_team_skills(sandbox:, slugs:)
        repo_slugs = Agent::Workspace.repo_slugs
        slugs.each do |slug|
          next if repo_slugs.include?(slug)
          next unless Skill::SLUG_FORMAT.match?(slug)

          files = read_sandbox_skill_files(sandbox, slug)
          next if files.empty?

          workspace.ingest_team_skill_from_files(slug: slug, files: files, by: conversation.user)
        end

        # Imports are independent of touched-slug writes — drain even on a
        # turn where no skill files changed.
        queue_skill_imports(sandbox: sandbox)
      rescue StandardError => e
        Rails.logger.warn("ingest_team_skills failed for conversation #{conversation.id}: #{e.message}")
      end

      def queue_skill_imports(sandbox:)
        path = "#{WORKSPACE_DIR}/#{Agent::Workspace::SKILLS_SUBPATH}/#{Agent::Workspace::SKILL_IMPORTS_FILE}"
        return unless sandbox.files.exists?(path)

        Agent::Workspace.enqueue_imports(
          body: sandbox.files.read(path),
          team_id: conversation.team_id,
          by_user_id: conversation.user_id
        )
      rescue StandardError => e
        Rails.logger.warn("queue_skill_imports failed for conversation #{conversation.id}: #{e.message}")
      end

      # Adds the microVM's id, so a turn can be traced to its sandbox in
      # E2B's logs.
      def runtime_info
        super.merge("sandbox_id" => @sandbox_id)
      end

      private

      def execute(sandbox, pi_args:)
        emit_status(:preparing, "Preparing workspace")
        timed(:provision) { provision(sandbox) }
        # Individual stage_* timings below overlap (they run concurrently);
        # :staging is the wall-clock that actually counts.
        timed(:staging) { stage_projected_inputs(sandbox) }
        session = PiAgent.session(transport_factory: transport_factory(sandbox, pi_args, sandbox_env))
        begin
          timed(:pi_session) { yield session }
        ensure
          session.close
        end
      end

      # Resume the conversation's paused sandbox, or create one if there
      # isn't a usable one. A stored id that no longer resolves (E2B-side
      # cleanup, manual kill, ancient paused sandbox the eviction job
      # already collected) is cleared and we fall back to fresh provision.
      def acquire_sandbox
        if conversation.e2b_sandbox_id.present?
          resume_existing
        else
          create_fresh
        end
      end

      def resume_existing
        emit_status(:resuming, "Resuming sandbox")
        sandbox = E2B::Sandbox.connect(conversation.e2b_sandbox_id)
        sandbox.resume(timeout: SANDBOX_TIMEOUT)
        @sandbox_was_resumed = true
        sandbox
      rescue E2B::NotFoundError
        Rails.logger.info(
          "E2B sandbox #{conversation.e2b_sandbox_id} not found for conversation " \
          "#{conversation.id}; provisioning fresh"
        )
        conversation.update_column(:e2b_sandbox_id, nil)
        create_fresh
      end

      def create_fresh
        emit_status(:creating, "Creating sandbox")
        @sandbox_was_resumed = false
        E2B::Sandbox.create(template: template, timeout: SANDBOX_TIMEOUT)
      end

      # Pause the sandbox so the next turn can resume it; persist the id
      # if it changed (first turn) or was cleared. Logged-not-raised:
      # a pause failure at end-of-turn must not crash the turn the user
      # already saw. If pause fails we best-effort kill the VM so it
      # doesn't leak as a running orphan, and clear the id — next turn
      # will provision fresh.
      def pause_sandbox(sandbox)
        sandbox.pause
        conversation.update_column(:e2b_sandbox_id, sandbox.sandbox_id) \
          if conversation.e2b_sandbox_id != sandbox.sandbox_id
      rescue StandardError => e
        Rails.logger.warn("E2B sandbox pause failed for conversation #{conversation.id}: #{e.message}")
        force_kill_after_pause_failure(sandbox)
        conversation.update_column(:e2b_sandbox_id, nil)
      end

      def force_kill_after_pause_failure(sandbox)
        sandbox.kill
      rescue StandardError
        # nothing more to do — log was already written by pause_sandbox
      end

      def provision(sandbox)
        sandbox.commands.run("mkdir -p #{SESSION_DIR} #{WORKSPACE_DIR}/uploads")
      end

      # Copy the baked repo .pi/skills/ tree from the template image
      # into the conversation workspace. One sandbox-local cp instead
      # of ~300 per-file upload RPCs over the wire. No-op on resumed
      # sandboxes (the tree persists via pause/resume) and on dev
      # sandboxes whose template predates the bake.
      def stage_repo_skills_from_template(sandbox)
        return unless sandbox.files.exists?(BAKED_REPO_SKILLS_DIR)

        dest = "#{WORKSPACE_DIR}/#{Agent::Workspace::SKILLS_SUBPATH}"
        sandbox.commands.run(
          "rm -rf #{Shellwords.escape(dest)} && " \
          "mkdir -p #{Shellwords.escape(File.dirname(dest))} && " \
          "cp -r #{Shellwords.escape(BAKED_REPO_SKILLS_DIR)} #{Shellwords.escape(dest)}"
        )
      end

      # Upload the app's pi extensions into the sandbox so `pi --extension`
      # can load them. Re-staged each turn even on a resumed sandbox so
      # an update to a bundled extension reaches in-flight conversations.
      def stage_extensions(sandbox)
        sources = Agent::Runtime.extension_sources
        return if sources.empty?

        sandbox.commands.run("mkdir -p #{EXTENSIONS_DIR}")
        sources.each do |source|
          sandbox.files.write(sandbox_extension_path(source), File.binread(source))
        end
      end

      # An extension's path inside the sandbox. Each extension is a
      # <name>/index.ts; the upload is named <name>.ts so distinct
      # extensions do not collide on the shared index.ts basename.
      def sandbox_extension_path(source)
        "#{EXTENSIONS_DIR}/#{source.parent.basename}.ts"
      end

      # Read every file under WORKSPACE_DIR/.pi/skills/<slug>/ in the
      # sandbox into an in-memory map keyed by relative path. One list
      # RPC + one read per file. Skill dirs are small (SKILL.md plus
      # a handful of supporting files), so the cost is bounded.
      def read_sandbox_skill_files(sandbox, slug)
        root = "#{WORKSPACE_DIR}/#{Agent::Workspace::SKILLS_SUBPATH}/#{slug}"
        return {} unless sandbox.files.exists?(root)

        files = {}
        list_sandbox_files(sandbox, root).each do |entry|
          rel = entry.path.delete_prefix("#{root}/")
          files[rel] = sandbox.files.read(entry.path, format: "bytes")
        end
        files
      end

      # Need workspace for the DB-side ingest helper.
      def workspace
        @workspace ||= Agent::Workspace.persistent(conversation)
      end

      # Project the conversation's uploaded files into uploads/. Re-
      # staged each turn (the canonical source is the Message
      # attachment, not the sandbox copy). Filenames are basenamed so a
      # crafted name cannot escape the uploads dir.
      def stage_uploads(sandbox)
        conversation.uploaded_files.each do |attachment|
          name = File.basename(attachment.filename.to_s)
          next if name.blank? || [ ".", ".." ].include?(name)

          sandbox.files.write("#{WORKSPACE_DIR}/uploads/#{name}", attachment.download)
        end
      end

      # Write the rendered .mcp.json into the sandbox workspace — a
      # per-turn projected input, overwriting any prior turn's copy.
      def stage_mcp_config(sandbox)
        sandbox.files.write("#{WORKSPACE_DIR}/#{Agent::McpConfig::FILENAME}", mcp_config)
      end

      # Delete .mcp.json before #pause_sandbox so the snapshot E2B
      # persists server-side between turns never holds the live bearer
      # tokens it carries. Re-staged next turn by #stage_mcp_config.
      # Logged-not-raised — cleanup must not crash a streamed turn.
      def discard_mcp_config(sandbox)
        path = "#{WORKSPACE_DIR}/#{Agent::McpConfig::FILENAME}"
        sandbox.commands.run("rm -f #{Shellwords.escape(path)}")
      rescue StandardError => e
        Rails.logger.warn("E2B mcp config cleanup failed for conversation #{conversation.id}: #{e.message}")
      end

      # Write the rendered AGENTS.md into the sandbox workspace. Per-turn
      # projected input. pi auto-loads it from `cwd` as ambient
      # instructions.
      def stage_identity(sandbox)
        sandbox.files.write("#{WORKSPACE_DIR}/#{Agent::Identity::FILENAME}", identity_content)
      end

      # Project skills into the sandbox at WORKSPACE_DIR/.pi/skills/.
      # pi auto-discovers from cwd, so both repo skills and team skills
      # land in one tree.
      #
      # Repo skills: the template image ships .pi/skills/ at
      # BAKED_REPO_SKILLS_DIR. On a fresh sandbox we copy it into the
      # workspace with one sandbox-local cp; on resumed sandboxes we
      # trust pause/resume to have preserved the tree. If the template
      # predates the bake and BAKED_REPO_SKILLS_DIR is absent, we fall
      # back to uploading from the host (slow but correct).
      #
      # Team skills: re-staged every turn — small in number, may
      # change between turns via the operator UI or agent authoring.
      # Stale team-skill dirs (operator-deleted or disabled) are
      # cleaned up by listing the tree.
      def stage_skills(sandbox)
        dest_root = "#{WORKSPACE_DIR}/#{Agent::Workspace::SKILLS_SUBPATH}"

        unless @sandbox_was_resumed
          timed(:skills_repo) do
            if sandbox.files.exists?(BAKED_REPO_SKILLS_DIR)
              stage_repo_skills_from_template(sandbox)
            else
              # Legacy fallback for templates built before the bake.
              sandbox.commands.run("rm -rf #{Shellwords.escape(dest_root)}")
              stage_repo_skills_from_host(sandbox, dest_root)
            end
          end
        end

        timed(:skills_team) { stage_team_skills(sandbox, dest_root) }
      end

      def stage_repo_skills_from_host(sandbox, dest_root)
        source = Agent::Workspace::SKILLS_SOURCE
        return unless source.directory?

        Dir.glob(source.join("**/*"), File::FNM_DOTMATCH).each do |path|
          next if File.directory?(path)
          next if File.basename(path).match?(/\A\.{1,2}\z/)

          rel = Pathname.new(path).relative_path_from(source).to_s
          sandbox.files.write("#{dest_root}/#{rel}", File.binread(path))
        end
      end

      TEAM_SKILLS_MARKER = ".team-skills.sig".freeze

      def stage_team_skills(sandbox, dest_root)
        signature = Skill.team_signature(conversation.team)
        marker_path = "#{dest_root}/#{TEAM_SKILLS_MARKER}"

        # No-drift path on a resumed sandbox: ~17 RPCs → 1.
        if @sandbox_was_resumed && sandbox.files.exists?(marker_path)
          return if sandbox.files.read(marker_path) == signature
        end

        enabled = conversation.team.skills.enabled.to_a

        # Pruning stale dirs and clearing each slug dir before re-writing only
        # matters on a resumed sandbox — a fresh one's skills dir was just
        # created, so there is nothing stale; skip those RPCs on fresh.
        if @sandbox_was_resumed && sandbox.files.exists?(dest_root)
          repo_slugs = Agent::Workspace.repo_slugs
          enabled_slugs = enabled.map(&:slug).to_set
          sandbox.files.list(dest_root).each do |entry|
            next if entry.file?

            slug = File.basename(entry.path)
            next if repo_slugs.include?(slug)
            next if enabled_slugs.include?(slug)

            sandbox.commands.run("rm -rf #{Shellwords.escape(entry.path)}")
          end
        end

        enabled.each do |skill|
          slug_dir = "#{dest_root}/#{skill.slug}"
          sandbox.commands.run("rm -rf #{Shellwords.escape(slug_dir)}") if @sandbox_was_resumed
          skill.files.each do |file|
            rel = Pathname.new(skill.relative_path(file)).cleanpath.to_s
            next if rel.start_with?("..") || rel.start_with?("/")

            sandbox.files.write("#{slug_dir}/#{rel}", file.download)
          end
        end

        # Stamp last — a mid-stage failure leaves a stale signature, next turn reapplies.
        sandbox.files.write(marker_path, signature)
      end

      # Must run before #pause_sandbox — a paused sandbox's filesystem
      # is unreachable.
      def collect_sandbox_artifacts(sandbox, since:)
        return unless sandbox.files.exists?(ARTIFACTS_DIR)

        list_sandbox_files(sandbox, ARTIFACTS_DIR).each do |entry|
          next unless entry.modified_time && entry.modified_time >= since

          if entry.size > MAX_ARTIFACT_BYTES
            Rails.logger.warn("Skipping oversized artifact #{entry.path} (#{entry.size} bytes)")
            next
          end

          bytes = sandbox.files.read(entry.path, format: "bytes")
          rel = entry.path.delete_prefix("#{ARTIFACTS_DIR}/")
          @artifacts << { filename: rel, io: StringIO.new(bytes) }
        end
      rescue StandardError => e
        Rails.logger.warn("E2B artifact collection failed for conversation #{conversation.id}: #{e.message}")
      end

      def list_sandbox_files(sandbox, root)
        files = []
        stack = [ root ]
        until stack.empty?
          entries = sandbox.files.list(stack.pop)
          entries.each do |entry|
            if entry.file?
              files << entry
            elsif entry.directory?
              stack << entry.path
            end
          end
        end
        files
      end

      def transport_factory(sandbox, pi_args, envs)
        command = Shellwords.join([ "pi", *pi_args ])
        lambda do |on_message:, on_stderr:|
          E2bTransport.new(
            sandbox: sandbox, command: command, cwd: WORKSPACE_DIR, envs: envs,
            on_message: on_message, on_stderr: on_stderr
          )
        end
      end

      def template
        Rails.application.config.x.agent.e2b_template
      end
    end
  end
end
