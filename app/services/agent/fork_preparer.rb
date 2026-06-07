require "fileutils"

module Agent
  # Copies the source's pi session + workspace into the fork's scope, truncated
  # to the snapshot, so its first turn --continues pi's real memory. Runs in
  # ChatJob — the worker that can see the host scope. Best-effort: failure
  # degrades to a history-replay fork (see #needs_history_replay?).
  class ForkPreparer
    def self.prepare(conversation)
      new(conversation).prepare
    end

    def initialize(conversation)
      @conversation = conversation
      @message = conversation.forked_from_message
    end

    def prepare
      return unless @conversation.fork_pending?
      return @conversation.update_columns(fork_pending: false) unless source

      copy_scope
      SessionTree.truncate_before_user(
        session_dir: dst.session_dir,
        user_index: ForkPlan.new(@message).truncate_user_index
      )
      @conversation.update_columns(
        backend_session_id: source.backend_session_id.presence || "forked",
        fork_pending: false
      )
    rescue StandardError => e
      Rails.logger.warn("ForkPreparer failed for conversation #{@conversation.id}: #{e.message}")
      @conversation.update_columns(fork_pending: false)
    end

    private

    def source = @message&.conversation

    def src = @src ||= Agent::Workspace.persistent(source)
    def dst = @dst ||= Agent::Workspace.persistent(@conversation)

    def copy_scope
      dst.reset!
      copy_dir(src.session_dir, dst.session_dir)
      copy_dir(src.workspace_dir, dst.workspace_dir)
      # .mcp.json carries live OAuth tokens and is re-staged each turn anyway.
      FileUtils.rm_f(dst.workspace_dir.join(McpConfig::FILENAME))
    end

    def copy_dir(from, to)
      return unless File.directory?(from)

      FileUtils.mkdir_p(to)
      FileUtils.cp_r(File.join(from.to_s, "."), to.to_s)
    end
  end
end
