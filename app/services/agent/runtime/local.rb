module Agent
  module Runtime
    # Runs pi as a local subprocess — the single-operator / development
    # runtime. NOT an isolation boundary: pi has shell access and `bash`
    # escapes the workspace. Isolation is what Docker and E2b are for.
    #
    # Persistence is pi-native. The scope lives in a persistent,
    # conversation-stable directory, and pi's own --session-dir +
    # --continue carry continuity between turns. See
    # docs/session-persistence.md.
    class Local < Base
      # Control-plane session (Agent::Runtime.control_session): pi as a
      # local subprocess, no workspace. The host's pi answers; `env`
      # carries the deployment's provider keys so pi advertises them.
      def self.control_session(env: {})
        session = PiAgent.session(args: %w[--mode rpc], env: env)
        yield session
      ensure
        session&.close
      end

      def session_dir
        workspace.session_dir
      end

      # pi runs on this host, so it loads the repo's extension files in
      # place — no staging needed.
      def extension_paths
        Agent::Runtime.extension_sources
      end

      def run(pi_args:)
        workspace.ensure!
        workspace.stage_uploads(conversation.uploaded_files)
        workspace.stage_mcp_config(mcp_config)
        workspace.stage_identity(identity_content)
        workspace.stage_skills
        # ext4 (CI) stores mtime at second granularity — a sub-second
        # start time can end up after a file written same-second.
        turn_started_at = Time.current.floor
        session = PiAgent.session(args: pi_args, cwd: workspace.workspace_dir.to_s)
        begin
          yield session
        ensure
          collect_host_artifacts(dir: workspace.artifacts_dir, since: turn_started_at)
          ingest_team_skills(slugs: touched_skill_slugs)
          session.close
          workspace.discard_mcp_config
        end
      end

      # Sync agent-written DB skills back from the host workspace.
      # Logged-not-raised — a sync hiccup must not crash the turn the
      # operator already saw stream.
      def ingest_team_skills(slugs:)
        workspace.ingest_team_skills(slugs: slugs, by: conversation.user)
        workspace.queue_skill_imports(by: conversation.user)
      rescue StandardError => e
        Rails.logger.warn("ingest_team_skills failed for conversation #{conversation.id}: #{e.message}")
      end

      private

      def workspace
        @workspace ||= Agent::Workspace.persistent(conversation)
      end
    end
  end
end
