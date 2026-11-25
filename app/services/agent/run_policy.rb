module Agent
  # What one turn may reach. A turn a routine started with nobody watching is
  # unattended: it gets only the connectors its routine grants and only the
  # HostBridge ops listed safe for it (new ops are refused until listed).
  # Anything else is attended and unrestricted.
  # See docs/unattended-runs.md.
  class RunPolicy
    UNATTENDED_OPS = %w[
      get_workflow get_project list_skills list_routines note_memory_applied note_memory_correction memory_report
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
      return true unless unattended?

      @conversation.team.connectors.where(name: @routine.granted_connectors)
                   .any? { |connector| connector.catalog_app&.oauth_provider == provider }
    end

    def op_allowed?(op)
      return true unless unattended?
      return @routine.may_start_workflows? if op == "start_workflow"
      return @routine.memory_review? if MEMORY_WRITE_OPS.include?(op)

      UNATTENDED_OPS.include?(op)
    end

    private

    def human_prompted?
      @conversation.messages.user.last&.sender_id.present?
    end
  end
end
