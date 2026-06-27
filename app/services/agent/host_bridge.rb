module Agent
  # Synchronous, read-only host calls from a sandboxed pi extension back into
  # Metis, over pi's Extension UI sub-protocol — the only sandbox→host channel
  # pi exposes (see docs/connectors.md and the pi-agent-rb ExtensionUI). The
  # extension calls `ctx.ui.input("metis:<op>", <json params>)`; pi forwards an
  # `extension_ui_request`; Agent::Adapters::Pi routes the "metis:"-prefixed
  # ones here and returns the JSON string as the dialog value, which the
  # extension parses into the tool result the model sees.
  #
  # READS ONLY. Writes stay out-of-band (Agent::WorkflowHandoff /
  # WorkflowAuthoring) so Rails fully owns validation and authorization — a
  # sandbox never holds Metis write credentials. Every op resolves within the
  # conversation's team, so a sandbox can't widen its own scope.
  class HostBridge
    PREFIX = "metis:".freeze

    # Allowlist — only these ops are dispatchable, and each maps to a method.
    OPS = %w[get_workflow].freeze

    # Build an `extension_ui:` handler bound to this conversation. It services
    # "metis:"-prefixed dialog requests as host calls and cancels everything
    # else (a genuine user dialog has nowhere to go in async web chat).
    def self.handler(conversation)
      lambda do |request|
        op = request.title.to_s
        next nil unless op.start_with?(PREFIX)

        call(conversation, op.delete_prefix(PREFIX), params_from(request))
      end
    end

    def self.params_from(request)
      JSON.parse(request.placeholder.to_s)
    rescue JSON::ParserError
      {}
    end

    # Returns a JSON string for the model, or nil to cancel the dialog. Runs
    # on the gem's per-request thread, so it checks out its own AR connection.
    # Never raises — a failed host call cancels the dialog, it doesn't crash
    # the turn.
    def self.call(conversation, op, params)
      return nil unless OPS.include?(op)

      ActiveRecord::Base.connection_pool.with_connection do
        new(conversation, params || {}).public_send(op)
      end
    rescue StandardError => e
      Rails.logger.error("HostBridge #{op} failed for conversation #{conversation.id}: #{e.class}: #{e.message}")
      nil
    end

    def initialize(conversation, params)
      @conversation = conversation
      @params = params
    end

    def get_workflow
      workflow = @conversation.team.workflows.named(@params["name"].to_s).first
      return nil unless workflow

      JSON.generate(
        name: workflow.name,
        description: workflow.description,
        enabled: workflow.enabled,
        default_project: workflow.default_project&.name,
        steps: workflow.steps
      )
    end
  end
end
