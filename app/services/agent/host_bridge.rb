module Agent
  # Synchronous host calls from a sandboxed pi extension back into Metis, over
  # pi's Extension UI sub-protocol — the only sandbox→host channel pi exposes
  # (see docs/connectors.md and the pi-agent-rb ExtensionUI). The extension
  # calls `ctx.ui.input("metis:<op>", <json params>)`; pi forwards an
  # `extension_ui_request`; Agent::Adapters::Pi routes the "metis:"-prefixed
  # ones here and returns the JSON string as the dialog value, which the
  # extension parses into the tool result the model sees.
  #
  # Reads and writes both go through here. The sandbox never holds Metis
  # credentials — it only sends a request; HostBridge does the work and
  # authorizes it server-side (admin for create/update/skill writes, membership
  # for start), always within the conversation's team, so a sandbox can't widen
  # its own scope. Writes delegate to Agent::WorkflowHandoff / WorkflowAuthoring
  # / SkillManager, which return `{ ok:, ... }` the agent relays in its reply.
  class HostBridge
    PREFIX = "metis:".freeze

    # Allowlist — only these ops are dispatchable, and each maps to a method.
    OPS = %w[
      get_workflow get_project start_workflow create_workflow update_workflow
      list_skills create_skill update_skill
    ].freeze

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

    def get_project
      project = @conversation.team.projects.named(@params["name"].to_s).first
      return nil unless project

      JSON.generate(
        name: project.name,
        about: project.about,
        github_repo: project.github_repo,
        linear_project: project.linear_project
      )
    end

    def start_workflow
      JSON.generate(Agent::WorkflowHandoff.from_tool_call(@conversation, @params))
    end

    def create_workflow
      JSON.generate(Agent::WorkflowAuthoring.create(@conversation, @params))
    end

    def update_workflow
      JSON.generate(Agent::WorkflowAuthoring.update(@conversation, @params))
    end

    def list_skills
      JSON.generate(Agent::SkillManager.list(@conversation))
    end

    def create_skill
      JSON.generate(Agent::SkillManager.create(@conversation, @params))
    end

    def update_skill
      JSON.generate(Agent::SkillManager.update(@conversation, @params))
    end
  end
end
