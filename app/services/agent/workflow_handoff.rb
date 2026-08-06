module Agent
  # The agent asked Metis to spin off a workflow run from this chat, via the
  # `metis_start_workflow` extension tool. The tool reaches Metis synchronously
  # over pi's Extension UI channel (Agent::HostBridge), so this returns a
  # structured result the agent relays in its own reply — it does not post into
  # the chat itself. Metis resolves the named workflow + project for the team
  # and seeds a fresh QUEUED run with this chat's transcript; the operator
  # reviews the seeded context and starts it. Never raises into the turn: a
  # failure becomes an `{ ok: false, error: }` the agent can report or retry.
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
      # another run from its own context, cascading without bound.
      return failure("Can't start a workflow from inside a workflow run.") if @conversation.workflow_run.present?

      workflow = resolve_workflow
      return failure("No enabled workflow named #{quoted(arg(:workflow))} on this team.") unless workflow

      project = resolve_project(workflow)
      return failure("Name a project to run #{quoted(workflow.name)} on, or set the workflow's default project.") unless project

      settings, error = resolve_settings
      return failure(error) if error

      # A queued run never runs a turn, so auto-titling can't name it — title
      # it now from the agent's note, else the workflow name.
      run = WorkflowRun.start(
        team: @conversation.team, user: @conversation.user,
        workflow: workflow, project: project, input: build_input,
        settings: settings, visibility: @conversation.visibility,
        trigger_summary: "Spun off from a chat", autostart: false,
        title: handoff_title(workflow), uploads: chat_uploads.map(&:blob)
      )
      {
        ok: true, queued: true, workflow: workflow.name, project: project.name,
        model: settings["model"].presence, provider: settings["provider"].presence,
        url: Rails.application.routes.url_helpers.conversation_path(run.conversation)
      }
    rescue StandardError => e
      Rails.logger.error("WorkflowHandoff failed for conversation #{@conversation.id}: #{e.class}: #{e.message}")
      failure("Something went wrong starting the workflow — nothing was launched.")
    end

    private

    def failure(error) = { ok: false, error: error }
    def quoted(value) = "\"#{value.presence || "?"}\""

    # The run inherits the launching chat's settings; an explicit provider/model
    # from the tool overrides them for the whole run, validated against the
    # deployment LLM catalog (Agent::ModelSelection). Returns [settings, error].
    def resolve_settings
      Agent::ModelSelection.resolve(@conversation.settings, model: arg(:model), provider: arg(:provider))
    end

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

    # The run's subject: the chat that led here, the agent's own summary of
    # what to do, and download links for the files the chat produced.
    # WorkflowRun.start folds this into the first step's prompt.
    def build_input
      transcript = TranscriptDigest.new(@conversation).to_s
      preamble = "Context from the chat that started this run:\n\n#{transcript}" if transcript.present?
      [ preamble, arg(:note).presence, uploads_block, artifacts_block ].compact.join("\n\n").presence
    end

    # The uploads themselves ride along on the run, so name the path, not a URL.
    def uploads_block
      names = chat_uploads.map { |attachment| attachment.filename.to_s }
      return if names.empty?

      "The operator's uploads from that chat are in `./uploads/`: #{names.join(', ')}"
    end

    # Artifacts stay links — the agent wrote them, they can be large, and a run
    # usually needs few. References in the transcript like `artifacts/spec.md`
    # are dead paths from another sandbox; these download URLs are not.
    def artifacts_block
      links = chat_artifacts.map { |attachment| "- #{attachment.filename}: #{blob_url(attachment)}" }
      return if links.empty?

      "Files the chat produced (download them before relying on them — they are " \
        "not in this run's workspace):\n#{links.join("\n")}"
    end

    def chat_uploads
      @chat_uploads ||= latest_per_name { |message| message.images.attachments + message.files.attachments }
    end

    def chat_artifacts
      @chat_artifacts ||= latest_per_name { |message| message.artifacts.attachments }
    end

    # One attachment per filename — a later turn's `report.csv` supersedes an
    # earlier one.
    def latest_per_name
      @chat_messages ||= @conversation.messages.chronological
        .with_attached_images.with_attached_files.with_attached_artifacts.to_a
      by_name = {}
      @chat_messages.each { |message| yield(message).each { |a| by_name[a.filename.to_s] = a } }
      by_name.values
    end

    def blob_url(attachment)
      Rails.application.routes.url_helpers.rails_blob_url(
        attachment, disposition: "attachment", **blob_url_options
      )
    end

    def blob_url_options
      Rails.application.config.action_mailer.default_url_options.presence || { host: "localhost", port: 3000 }
    end

    def handoff_title(workflow)
      arg(:note).presence&.truncate(Conversation::TITLE_MAX) || workflow.run_title
    end

    def arg(key)
      (@args[key.to_s] || @args[key.to_sym]).to_s.strip
    end
  end
end
