module Agent
  # The agent asked Metis to create or edit a team workflow template, via the
  # `metis_create_workflow` / `metis_update_workflow` extension tools. The tools
  # reach Metis synchronously over pi's Extension UI channel (Agent::HostBridge),
  # so these return a structured result the agent relays — they do not post into
  # the chat. Authoring is admin-gated in the UI (require_team_admin!), so this
  # enforces the same: a plain member's agent can't mutate shared templates.
  # Never raises into the turn — a failure becomes an `{ ok: false, error: }`.
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
      return failure("Can't author workflows from inside a workflow run.") if engine_run?
      return failure("Only team admins can create or edit workflows.") unless admin?

      steps = Workflow.normalize_steps(@args["steps"] || @args[:steps])
      return failure("A workflow needs at least one step with a prompt.") if steps.empty?

      project, error = resolve_project
      return failure(error) if error

      workflow = @conversation.team.workflows.new(
        name: arg(:name), description: arg(:description).presence,
        steps: steps, default_project: project
      )
      save_result(workflow, "created")
    rescue StandardError => e
      log_and_fail(e)
    end

    def update
      return failure("Can't author workflows from inside a workflow run.") if engine_run?
      return failure("Only team admins can create or edit workflows.") unless admin?

      workflow = @conversation.team.workflows.named(arg(:name)).first
      return failure("No workflow named #{quoted(arg(:name))} on this team.") unless workflow

      if has_arg?(:steps)
        steps = Workflow.normalize_steps(@args["steps"] || @args[:steps])
        return failure("A workflow needs at least one step with a prompt.") if steps.empty?

        workflow.steps = steps
      end
      workflow.description = arg(:description).presence if has_arg?(:description)

      project, error = resolve_project
      return failure(error) if error

      workflow.default_project = project if has_arg?(:project)
      save_result(workflow, "updated")
    rescue StandardError => e
      log_and_fail(e)
    end

    private

    # A workflow run's turns are engine-driven; mutating team templates as a
    # side effect of an automated run would be surprising. Author only from a
    # human-driven chat, the same boundary WorkflowHandoff draws.
    def engine_run?
      @conversation.workflow_run.present?
    end

    def admin? = @conversation.team.managed_by?(@conversation.user)

    # [project, error]. No project named → [nil, nil] (default stays unset).
    # A named project that doesn't resolve is an error the operator must fix.
    def resolve_project
      name = arg(:project)
      return [ nil, nil ] if name.blank?

      project = @conversation.team.projects.named(name).first
      project ? [ project, nil ] : [ nil, "No project named #{quoted(name)} on this team." ]
    end

    def save_result(workflow, action)
      if workflow.save
        { ok: true, action: action, name: workflow.name,
          url: Rails.application.routes.url_helpers.edit_workflow_path(workflow) }
      else
        failure(workflow.errors.full_messages.join("; "))
      end
    end

    def log_and_fail(error)
      Rails.logger.error("WorkflowAuthoring failed for conversation #{@conversation.id}: #{error.class}: #{error.message}")
      failure("Something went wrong saving the workflow — nothing was changed.")
    end

    def failure(error) = { ok: false, error: error }
    def quoted(value) = "\"#{value.presence || "?"}\""

    def has_arg?(key)
      @args.key?(key.to_s) || @args.key?(key.to_sym)
    end

    def arg(key)
      (@args[key.to_s] || @args[key.to_sym]).to_s.strip
    end
  end
end
