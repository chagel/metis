module Agent
  # Metis user message N maps 1:1 to pi user entry N.
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
            .with_attached_images.with_attached_files.with_attached_artifacts
    end

    # The pi user entry after the forked turn; >= the count means clone.
    def truncate_user_index
      ordered = source.messages.user.chronological.pluck(:id)
      prior = ordered.rindex { |id| id < message.id }
      prior ? prior + 1 : 0
    end

    def host_eligible?
      HOST_RUNTIMES.include?(@current_runtime) &&
        HOST_RUNTIMES.include?(source.runtime_label.to_s)
    end
  end
end
