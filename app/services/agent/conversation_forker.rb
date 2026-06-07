module Agent
  # The real pi session copy is deferred to ForkPreparer on the first turn.
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
          created_at: src.created_at, # read as history, not stamped at fork time
          started_at: src.started_at,
          finished_at: src.finished_at
        )
        copy_attachments(src, copy)
      end
    end

    # Usage columns stay nil so the fork's first turn accounts its own.
    def copy_attachments(src, dst)
      dst.images.attach(src.images.blobs) if src.images.attached?
      dst.files.attach(src.files.blobs) if src.files.attached?
      dst.artifacts.attach(src.artifacts.blobs) if src.artifacts.attached?
    end
  end
end
