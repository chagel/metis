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
      @unattended = (@routine.present? || conversation.settings["fired_by_routine"]) && !human_prompted?
    end

    def unattended? = @unattended

    # A CLI connector works only through its provider's token.
    def connector_allowed?(connector)
      provider = connector.cli? && connector.catalog_app&.oauth_provider
      provider ? provider_allowed?(provider) : allowed_server?(connector.name)
    end

    def allowed_server?(name)
      !unattended? || granted_names.include?(name)
    end

    # The sandbox's CLI tokens (GH_TOKEN, the gws token) carry the user's whole
    # grant for a provider, so they need every connector on it granted.
    def provider_allowed?(provider)
      return true unless unattended?

      names = @conversation.team.connectors.select { |connector| connector.catalog_app&.oauth_provider == provider }.map(&:name)
      names.any? && (names - granted_names).empty?
    end

    def op_allowed?(op)
      return true unless unattended?
      return !!@routine&.may_start_workflows? if op == "start_workflow"
      return !!@routine&.memory_review? if MEMORY_WRITE_OPS.include?(op)

      UNATTENDED_OPS.include?(op)
    end

    private

    # A deleted routine leaves its queued fires with nothing granted.
    def granted_names
      @routine&.granted_connectors || []
    end

    def human_prompted?
      @conversation.messages.user.last&.sender_id.present?
    end
  end
end
