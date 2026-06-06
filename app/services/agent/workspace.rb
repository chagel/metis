require "fileutils"

module Agent
  # Resolves the on-disk scope for a conversation's agent run and stages
  # per-turn inputs into it. See docs/session-persistence.md for layout
  # and the per-runtime persistence model.
  class Workspace
    SCRATCH_ROOT = Rails.root.join("tmp/agent").freeze
    # In test, route persistent scopes under tmp/ so the suite's
    # rm_rf teardowns can never alias a dev user's storage/agent/uN
    # (sequences in the dev and test DBs collide on small ids). Outside
    # test, METIS_PERSISTENT_ROOT can point this at a host directory
    # bind-mounted at an identical path into the job container — required
    # by Runtime::Docker under Docker-in-Docker so the per-turn bind mount
    # resolves to the same files on host and container (docs/coding-runtime.md).
    PERSISTENT_ROOT =
      if Rails.env.test?
        Rails.root.join("tmp/agent_persistent_test").freeze
      elsif ENV["METIS_PERSISTENT_ROOT"].present?
        Pathname.new(ENV["METIS_PERSISTENT_ROOT"]).freeze
      else
        Rails.root.join("storage/agent").freeze
      end
    SKILLS_SOURCE = Rails.root.join(".pi/skills").freeze
    SKILLS_SUBPATH = ".pi/skills".freeze
    # Mirrors Runtime::E2b#TEAM_SKILLS_MARKER — see stage_skills.
    SKILLS_MARKER = ".staged.sig".freeze
    # Agent-written sentinel — one GitHub source per line, drained by
    # the runtime into ImportSkillJob enqueues at turn end.
    SKILL_IMPORTS_FILE = ".imports".freeze
    ARTIFACTS_SUBPATH = "artifacts".freeze

    def self.scratch(conversation)
      new(conversation, SCRATCH_ROOT)
    end

    def self.persistent(conversation)
      new(conversation, PERSISTENT_ROOT)
    end

    def initialize(conversation, root)
      @conversation = conversation
      @root = root
    end

    # The conversation's whole scope.
    def scope_dir
      @root.join("u#{@conversation.user_id}", "c#{@conversation.id}")
    end

    def session_dir = scope_dir.join("sessions")
    def workspace_dir = scope_dir.join("workspace")
    def uploads_dir = workspace_dir.join("uploads")
    def artifacts_dir = workspace_dir.join(ARTIFACTS_SUBPATH)
    def skills_dir = workspace_dir.join(SKILLS_SUBPATH)

    # Discard any stale scope and recreate it empty — for a runtime that
    # repopulates it from the archive.
    def reset!
      FileUtils.rm_rf(scope_dir)
      ensure!
    end

    # Create the scope directories if absent, leaving existing content.
    def ensure!
      [ session_dir, workspace_dir, uploads_dir ].each { |dir| FileUtils.mkdir_p(dir) }
      self
    end

    # Project uploaded file attachments into uploads/. Filenames are
    # basenamed so a crafted name cannot escape the workspace.
    def stage_uploads(attachments)
      FileUtils.mkdir_p(uploads_dir)
      attachments.each do |attachment|
        name = File.basename(attachment.filename.to_s)
        next if name.blank? || [ ".", ".." ].include?(name)

        attachment.open { |io| IO.copy_stream(io, uploads_dir.join(name)) }
      end
    end

    # Write the rendered .mcp.json into the workspace root — a per-turn
    # projected input like uploads/, overwritten each turn and never
    # archived (see docs/connectors.md). It carries live OAuth bearer
    # tokens, so it is written 0600 and discarded at turn end
    # (#discard_mcp_config) — the rendered token must not linger on disk.
    def stage_mcp_config(content)
      path = workspace_dir.join(McpConfig::FILENAME)
      File.write(path, content)
      File.chmod(0o600, path)
    end

    # Remove the token-bearing .mcp.json so rendered bearer tokens do not
    # outlive the turn on disk. Re-staged next turn. Best-effort.
    def discard_mcp_config
      FileUtils.rm_f(workspace_dir.join(McpConfig::FILENAME))
    end

    # Write the rendered AGENTS.md into the workspace root. pi auto-loads
    # it from `cwd` as ambient instructions — the agent boots reading
    # this every turn. Per-turn projected input like .mcp.json: rendered
    # fresh each turn, never archived. See Agent::Identity.
    def stage_identity(content)
      File.write(workspace_dir.join(Identity::FILENAME), content)
    end

    # Mirrors Runtime::E2b#stage_team_skills — skips when the marker matches.
    def stage_skills
      dest = skills_dir
      signature = staged_skills_signature
      marker = dest.join(SKILLS_MARKER)

      return if marker.file? && marker.read == signature

      FileUtils.rm_rf(dest)

      if SKILLS_SOURCE.directory?
        FileUtils.mkdir_p(dest.dirname)
        FileUtils.cp_r(SKILLS_SOURCE, dest)
      end

      team_skills = @conversation.team.skills.enabled
      if team_skills.any?
        FileUtils.mkdir_p(dest)
        team_skills.find_each { |skill| skill.extract_to(dest.join(skill.slug)) }
      end

      return unless dest.directory?

      # Stamp last — a mid-stage crash leaves a stale signature, next turn re-stages.
      File.write(marker, signature)
    end

    def staged_skills_signature
      Digest::SHA1.hexdigest("#{self.class.repo_skills_fingerprint}|#{Skill.team_signature(@conversation.team)}")
    end

    # Memoized for the life of the process — SKILLS_SOURCE doesn't change
    # between turns of a deployed checkout.
    def self.repo_skills_fingerprint
      return @repo_skills_fingerprint if @repo_skills_fingerprint
      return @repo_skills_fingerprint = "" unless SKILLS_SOURCE.directory?

      base = "#{SKILLS_SOURCE}/"
      payload = Dir.glob(SKILLS_SOURCE.join("**/*"), File::FNM_DOTMATCH)
        .reject { |p| File.directory?(p) }
        .sort
        .map { |f| "#{f.delete_prefix(base)}:#{File.size(f)}:#{File.mtime(f).to_i}" }
        .join(",")
      @repo_skills_fingerprint = Digest::SHA1.hexdigest(payload)
    end

    def self.reset_repo_skills_fingerprint!
      @repo_skills_fingerprint = nil
    end

    # Upsert agent-touched team skills. Adapter pre-filters to slugs the agent
    # actually wrote; repo slugs are excluded as a runtime guard. Never deletes
    # — operator UI owns that.
    def ingest_team_skills(slugs:, by:)
      return if slugs.empty?
      return unless skills_dir.directory?

      repo_slugs = self.class.repo_slugs
      slugs.each do |slug|
        next if repo_slugs.include?(slug)
        next unless Skill::SLUG_FORMAT.match?(slug)

        ingest_one_skill_from_disk(skills_dir.join(slug), by: by)
      end
    end

    # Drain the agent-written .imports sentinel from disk; Runtime::E2b
    # reads from the sandbox and calls .enqueue_imports directly.
    def queue_skill_imports(by:)
      file = skills_dir.join(SKILL_IMPORTS_FILE)
      return unless file.file?

      self.class.enqueue_imports(body: file.read, team_id: @conversation.team_id, by_user_id: by.id)
    rescue StandardError => e
      Rails.logger.warn("queue_skill_imports failed for conversation #{@conversation.id}: #{e.message}")
    end

    # Parse the sentinel body (one source per line, # comments, blanks
    # skipped) and enqueue one ImportSkillJob per unique entry. Shared
    # between Workspace (Local/Docker, reads from disk) and Runtime::E2b
    # (reads from the sandbox).
    def self.enqueue_imports(body:, team_id:, by_user_id:)
      body.to_s.each_line.map(&:strip)
        .reject { |l| l.empty? || l.start_with?("#") }
        .uniq
        .each { |source| ImportSkillJob.perform_later(team_id: team_id, by_user_id: by_user_id, url: source) }
    end

    # `files`: relative path -> bytes, must include SKILL.md. Logged-not-raised.
    def ingest_team_skill_from_files(slug:, files:, by:)
      return unless Skill::SLUG_FORMAT.match?(slug)
      return if self.class.repo_slugs.include?(slug)

      Skill.upsert_from_files(team: @conversation.team, slug: slug, files: files, by: by)
    rescue StandardError => e
      Rails.logger.warn("ingest_team_skill(slug=#{slug}) failed for conversation #{@conversation.id}: #{e.message}")
    end

    # Slugs shipped at .pi/skills/. Filters ingest + validates that a
    # team slug never shadows a repo skill.
    def self.repo_slugs
      return Set.new unless SKILLS_SOURCE.directory?

      SKILLS_SOURCE.children
        .select(&:directory?)
        .map { |p| p.basename.to_s }
        .to_set
    end

    private

    def ingest_one_skill_from_disk(skill_dir, by:)
      return unless skill_dir.directory?

      files = skill_dir.glob("**/*").reject(&:directory?).each_with_object({}) do |path, h|
        rel = path.relative_path_from(skill_dir).to_s
        h[rel] = path.binread
      end
      return if files.empty?

      ingest_team_skill_from_files(slug: skill_dir.basename.to_s, files: files, by: by)
    end
  end
end
