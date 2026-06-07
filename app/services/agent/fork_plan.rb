module Agent
  # What "fork from this assistant turn" means, shared by ConversationForker
  # (request time) and ForkPreparer (first turn). Metis user message N maps
  # 1:1 to pi user entry N.
  class ForkPlan
    HOST_RUNTIMES = %w[local docker].freeze

    def initialize(message, current_runtime: Rails.application.config.x.agent.runtime)
      @message = message
      @source = message.conversation
      @current_runtime = current_runtime.to_s
    end

    attr_reader :message, :source

    def copied_messages
      source.messages.chronological.where("messages.id <= ?", message.id)
    end

    # First pi user entry to drop when truncating the session: the turn after
    # the forked one. >= the user-entry count keeps everything (a clone).
    def truncate_user_index
      ordered = source.messages.user.chronological.pluck(:id)
      prior = ordered.rindex { |id| id < message.id }
      prior ? prior + 1 : 0
    end

    # A real session copy needs the transcript on the host filesystem — both
    # the source's last runtime and the current one. Else: history replay.
    def host_eligible?
      HOST_RUNTIMES.include?(@current_runtime) &&
        HOST_RUNTIMES.include?(source.runtime_label.to_s)
    end
  end
end
