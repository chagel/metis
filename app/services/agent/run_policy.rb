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
    GRANTABLE_OPS = %w[start_workflow].freeze

    def self.for(conversation) = new(conversation)

    def self.provider_grant(provider) = "provider:#{provider}"

    def initialize(conversation)
      @conversation = conversation
      @routine = conversation.routine
      @unattended = (@routine.present? || conversation.settings["fired_by_routine"]) && !human_prompted?
    end

    def unattended? = @unattended

    # Connectors on an OAuth provider share the user's token, so they're
    # granted together.
    def connector_allowed?(connector)
      provider = connector.catalog_app&.oauth_provider
      provider ? provider_allowed?(provider) : allowed_server?(connector.name)
    end

    def allowed_server?(name)
      !unattended? || granted_names.include?(name)
    end

    def provider_allowed?(provider)
      !unattended? || granted_names.include?(self.class.provider_grant(provider))
    end

    def op_allowed?(op)
      return true unless unattended?
      return !!@routine&.memory_review? if MEMORY_WRITE_OPS.include?(op)

      UNATTENDED_OPS.include?(op) || (GRANTABLE_OPS.include?(op) && Array(@routine&.granted_actions).include?(op))
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
