module Agent
  # Resolves what a "fork from this message" means, shared by the two halves
  # of the feature: ConversationForker (builds the fork + copies Metis rows at
  # request time) and ForkPreparer (copies + truncates the real pi session on
  # the fork's first turn).
  #
  # We fork from a completed assistant turn — "continue from after this answer
  # in a new thread". The new thread keeps everything through that turn; in
  # pi's session tree that means dropping every entry from the *next* user
  # message onward (a clone when the turn is the latest). Metis user message N
  # maps 1:1 to pi user entry N.
  class ForkPlan
    HOST_RUNTIMES = %w[local docker].freeze

    def initialize(message, current_runtime: Rails.application.config.x.agent.runtime)
      @message = message
      @source = message.conversation
      @current_runtime = current_runtime.to_s
    end

    attr_reader :message, :source

    # The source rows to copy into the fork, in order — through the forked turn.
    def copied_messages
      source.messages.chronological.where("messages.id <= ?", message.id)
    end

    # The first source user entry to drop when truncating pi's session tree:
    # the turn after the forked one. >= the user-entry count means "keep
    # everything" (a clone — the forked turn was the latest).
    def truncate_user_index
      ordered = source.messages.user.chronological.pluck(:id)
      prior = ordered.rindex { |id| id < message.id }
      prior ? prior + 1 : 0
    end

    # A real session copy is possible only when both the source's last runtime
    # and the current deployment runtime keep the session on the host
    # filesystem. Otherwise the fork falls back to history replay.
    def host_eligible?
      HOST_RUNTIMES.include?(@current_runtime) &&
        HOST_RUNTIMES.include?(source.runtime_label.to_s)
    end
  end
end
