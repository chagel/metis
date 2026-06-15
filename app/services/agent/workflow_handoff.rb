module Agent
  # The agent asked Metis to spin off a workflow run from this chat, via the
  # `metis_start_workflow` extension tool. Metis sees the tool call in the
  # event stream (ChatJob) and acts here, server-side: it resolves the named
  # workflow + project for the team, seeds a fresh run with this chat's
  # transcript, and posts a confirmation (or a precise error) back into the
  # chat. The tool's own ack can't carry the outcome — Metis acts out of band
  # — so this note is the operator's source of truth. Never raises into the
  # turn: a handoff failure must not sink the chat the operator is watching.
  class WorkflowHandoff
    def self.from_tool_call(conversation, args)
      new(conversation, args || {}).call
    end

    def initialize(conversation, args)
      @conversation = conversation
      @args = args
    end

    def call
      # A run's turns are engine-driven and their seeded input restates the
      # chat that launched them — honoring the tool here would let a run spawn
      # another run from its own context, cascading without bound. Ignore it.
      return if @conversation.workflow_run.present?

      workflow = resolve_workflow
      return notify(t("no_workflow", name: arg(:workflow).presence || "?")) unless workflow

      project = resolve_project(workflow)
      return notify(t("no_project", workflow: workflow.name)) unless project

      run = WorkflowRun.start(
        team: @conversation.team, user: @conversation.user,
        workflow: workflow, project: project, input: build_input,
        settings: @conversation.settings || {}, visibility: @conversation.visibility,
        trigger_summary: "Spun off from a chat"
      )
      notify(t("started", workflow: workflow.name, project: project.name,
                          url: Rails.application.routes.url_helpers.conversation_path(run.conversation)))
    rescue StandardError => e
      Rails.logger.error("WorkflowHandoff failed for conversation #{@conversation.id}: #{e.class}: #{e.message}")
      notify(t("failed"))
    end

    private

    def resolve_workflow
      name = arg(:workflow)
      return if name.blank?

      @conversation.team.workflows.enabled.named(name).first
    end

    # Named project wins; otherwise inherit the chat's project, then the
    # workflow's default. Nil means the run can't start (start demands one).
    def resolve_project(workflow)
      name = arg(:project)
      return @conversation.team.projects.named(name).first if name.present?

      @conversation.project || workflow.default_project
    end

    # The run's subject: the chat that led here, plus the agent's own summary
    # of what to do. WorkflowRun.start folds this into the first step's prompt.
    def build_input
      transcript = TranscriptDigest.new(@conversation).to_s
      preamble = "Context from the chat that started this run:\n\n#{transcript}" if transcript.present?
      [ preamble, arg(:note).presence ].compact.join("\n\n").presence
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

    def arg(key)
      (@args[key.to_s] || @args[key.to_sym]).to_s.strip
    end

    def t(key, **)
      I18n.t("handoff.#{key}", **)
    end
  end
end
