module Agent
  # The agent asked Metis to create or edit a team workflow template, via the
  # `metis_create_workflow` / `metis_update_workflow` extension tools. Like
  # WorkflowHandoff, Metis sees the tool call in the turn's event stream
  # (ChatJob) and acts server-side, out of band: it validates and persists the
  # Workflow, then posts a confirmation (or a precise error) back into the chat.
  # Authoring is admin-gated in the UI (require_team_admin!), so this enforces
  # the same — a plain member's agent can't mutate shared templates. Never
  # raises into the turn: an authoring failure must not sink the chat.
  class WorkflowAuthoring
    def self.create(conversation, args)
      new(conversation, args || {}).create
    end

    def self.update(conversation, args)
      new(conversation, args || {}).update
    end

    def initialize(conversation, args)
      @conversation = conversation
      @args = args
    end

    def create
      return if engine_run?
      return notify(t("forbidden")) unless admin?

      steps = Workflow.normalize_steps(@args["steps"] || @args[:steps])
      return notify(t("needs_steps")) if steps.empty?

      project, error = resolve_project
      return notify(error) if error

      workflow = @conversation.team.workflows.new(
        name: arg(:name), description: arg(:description).presence,
        steps: steps, default_project: project
      )
      save_and_notify(workflow, :created)
    rescue StandardError => e
      fail_safely(e)
    end

    def update
      return if engine_run?
      return notify(t("forbidden")) unless admin?

      workflow = @conversation.team.workflows.named(arg(:name)).first
      return notify(t("no_workflow", name: arg(:name).presence || "?")) unless workflow

      if has_arg?(:steps)
        steps = Workflow.normalize_steps(@args["steps"] || @args[:steps])
        return notify(t("needs_steps")) if steps.empty?

        workflow.steps = steps
      end
      workflow.description = arg(:description).presence if has_arg?(:description)

      project, error = resolve_project
      return notify(error) if error

      workflow.default_project = project if has_arg?(:project)
      save_and_notify(workflow, :updated)
    rescue StandardError => e
      fail_safely(e)
    end

    private

    # A workflow run's turns are engine-driven; mutating team templates as a
    # side effect of an automated run would be surprising. Author only from a
    # human-driven chat, the same boundary WorkflowHandoff draws.
    def engine_run?
      @conversation.workflow_run.present?
    end

    def admin?
      @conversation.user.memberships.find_by(team: @conversation.team)&.manages_team? || false
    end

    # [project, error]. No project named → [nil, nil] (default stays unset).
    # A named project that doesn't resolve is an error the operator must fix.
    def resolve_project
      name = arg(:project)
      return [ nil, nil ] if name.blank?

      project = @conversation.team.projects.named(name).first
      project ? [ project, nil ] : [ nil, t("no_project", name: name) ]
    end

    def save_and_notify(workflow, action)
      if workflow.save
        notify(t(action, name: workflow.name, url: edit_workflow_path(workflow)))
      else
        notify(t("invalid", errors: workflow.errors.full_messages.join("; ")))
      end
    end

    def edit_workflow_path(workflow)
      Rails.application.routes.url_helpers.edit_workflow_path(workflow)
    end

    def fail_safely(e)
      Rails.logger.error("WorkflowAuthoring failed for conversation #{@conversation.id}: #{e.class}: #{e.message}")
      notify(t("failed"))
    end

    def notify(content)
      message = @conversation.messages.create!(
        role: :assistant, content: content, streaming_status: :done, kind: :handoff
      )
      Turbo::StreamsChannel.broadcast_append_to(
        @conversation, target: "messages",
        partial: "messages/message", locals: { message: message }
      )
      nil
    end

    def has_arg?(key)
      @args.key?(key.to_s) || @args.key?(key.to_sym)
    end

    def arg(key)
      (@args[key.to_s] || @args[key.to_sym]).to_s.strip
    end

    def t(key, **)
      I18n.t("workflow_authoring.#{key}", **)
    end
  end
end
