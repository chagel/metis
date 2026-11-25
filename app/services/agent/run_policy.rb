module Agent
  # What one turn may reach. A turn a routine started with nobody watching is
  # unattended: it gets only the connectors its routine grants, no HostBridge
  # ops that could widen its own reach, and no memory writes outside the
  # memory review. Anything else is attended and unrestricted.
  # See docs/unattended-runs.md.
  class RunPolicy
    SELF_WIDENING_OPS = %w[
      create_workflow update_workflow create_skill update_skill create_routine update_routine
    ].freeze
    MEMORY_WRITE_OPS = %w[remember update_memory forget_memory].freeze

    def self.for(conversation) = new(conversation)

    def initialize(conversation)
      @conversation = conversation
      @routine = conversation.routine
      @unattended = @routine.present? && !human_prompted?
    end

    def unattended? = @unattended

    def connector_allowed?(connector)
      allowed_server?(connector.name)
    end

    def allowed_server?(name)
      !unattended? || @routine.granted_connectors.include?(name)
    end

    # The sandbox's CLI tokens (GH_TOKEN, the gws token) follow the grant of a
    # connector on the same OAuth provider.
    def provider_allowed?(provider)
      !unattended? || granted_connectors.any? { |connector| connector.catalog_app&.oauth_provider == provider }
    end

    def op_allowed?(op)
      return true unless unattended?
      return @routine.may_start_workflows? if op == "start_workflow"
      return @routine.memory_review? if MEMORY_WRITE_OPS.include?(op)

      SELF_WIDENING_OPS.exclude?(op)
    end

    private

    def human_prompted?
      @conversation.messages.where(role: :user).order(:id).last&.sender_id.present?
    end

    def granted_connectors
      @granted_connectors ||= @conversation.team.connectors.where(name: @routine.granted_connectors).to_a
    end
  end
end
