module Agent
  # Builds a new conversation forked from a source message: copies the Metis
  # message rows up to the fork point (so the new thread renders its inherited
  # history immediately) and flags whether the first turn should copy the real
  # pi session (#fork_pending, host-backed runtimes) or fall back to history
  # replay (cloud sources). The actual session copy is deferred to
  # Agent::ForkPreparer on the first turn — see docs/session-persistence.md.
  class ConversationForker
    def initialize(message, by:)
      @plan = ForkPlan.new(message)
      @user = by
    end

    def call
      fork = nil
      Conversation.transaction do
        fork = build_conversation
        fork.save!
        copy_messages(fork)
      end
      fork
    end

    private

    def source = @plan.source

    def build_conversation
      @user.conversations.new(
        team: source.team,
        project_id: source.project_id,
        settings: source.settings,
        title: source.title,
        forked_from_message: @plan.message,
        fork_pending: @plan.host_eligible?
      )
    end

    def copy_messages(fork)
      @plan.copied_messages.each do |src|
        copy = fork.messages.create!(
          role: src.role,
          content: src.content,
          reasoning: src.reasoning,
          tool_calls: src.tool_calls,
          streaming_status: :done,
          native_ref: src.native_ref,
          # Preserve the original timestamps so the inherited turns read as
          # history, not as if they all happened at fork time.
          created_at: src.created_at,
          started_at: src.started_at,
          finished_at: src.finished_at
        )
        copy_attachments(src, copy)
      end
    end

    # Share the underlying blobs — a fork inherits the same uploads/artifacts,
    # no re-upload. Usage columns (tokens/cost) are intentionally left nil:
    # the fork's first turn accounts its own usage from pi's fresh totals.
    def copy_attachments(src, dst)
      dst.images.attach(src.images.blobs) if src.images.attached?
      dst.files.attach(src.files.blobs) if src.files.attached?
      dst.artifacts.attach(src.artifacts.blobs) if src.artifacts.attached?
    end
  end
end
