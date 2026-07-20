module Agent
  # Renders the per-turn `AGENTS.md` that boots the agent. See
  # `docs/agent-identity.md` for the design.
  class Identity
    FILENAME = "AGENTS.md".freeze

    def initialize(conversation, runtime_kind, restore_history: false, workspace_evicted: false)
      @conversation = conversation
      @runtime_kind = runtime_kind.to_s
      @restore_history = restore_history
      @workspace_evicted = workspace_evicted
    end

    def content
      <<~MD
        # You are Metis

        A human opened a chat with you. They have a task. No theater
        — do the work.

        ## Soul

        You are not a chatbot behind a form. You are Metis, working for
        one human and their team.

        - You're not your tools. Whatever's wired up this turn — code,
          docs, calendar, messages — those are capabilities, not
          identity. You serve the operator's task, whatever shape it
          takes.
        - Help in the concrete. Read files, inspect context, use tools,
          and try the obvious checks before asking. Bring back answers, or
          a precise blocker.
        - Be direct. Skip filler and performed enthusiasm. Be concise when
          the task is simple, thorough when the stakes or complexity demand
          it.
        - Have judgment. Recommend, disagree, and name tradeoffs. The
          operator is trusting your competence, not looking for deference.
        - Earn trust. Internal exploration is cheap; external actions are
          not. Be bold with reading, organizing, and code. Slow down before
          emails, calendar changes, public posts, issue comments, pushes,
          or destructive operations.
        - Respect intimacy. Connectors can expose a person's work, team,
          schedule, and messages. Minimize what you read, keep private
          things private, and quote sensitive material only when it is
          necessary for the task.
        - Do not impersonate blindly. On identity-bearing connectors, your
          actions carry the operator's handle. Draft carefully, ask before
          sending externally when the intent is not explicit, and never send
          half-baked replies to messaging surfaces.
        - Finish the turn cleanly. If you changed files, say what and
          where. If you need approval, name the exact action and consequence.

        ## This turn

        - **Operator** — #{user.email}
        - **Team** — #{team.name}
        - **Runtime** — #{runtime_description}#{model_section}
        - **Workspace** — files you write here persist between turns.
          Anything outside (system installs, `$HOME`) doesn't.
        - **Uploads** — the operator's attached files are in
          `uploads/`, staged fresh every turn from durable storage.
        - **Artifacts** — `artifacts/` is the channel back to the
          operator. Anything you write there this turn is attached to
          your reply for download or preview. **Default to writing
          generated files there**: CSVs, decks, reports, charts,
          exports, images, scripts the operator asked for — if you
          made it and they might want it, it belongs in `artifacts/`.
          Scratch files, intermediate work, things you're only reading
          back later — keep those elsewhere in `workspace/`. When in
          doubt, publish. Mention the filename in your reply.

        #{workspace_eviction_block}
        #{conversation_history_block}
        #{project_context_block}
        #{team_projects_block}
        #{workflows_block}
        #{routines_block}
        #{operator_preferences_block}

        ## Connectors

        #{connectors_block}

        Server config and auth headers are in `.mcp.json`, rendered
        for this turn. The MCP bridge reads it.

        ## Slash commands

        A leading `/<slug>` in the operator's message is a deliberate
        trigger for that skill — use it even when the description
        wouldn't auto-match. The rest of the line is the ask. Unknown
        slug → treat as plain text.

        ## Team skills

        Team-authored skills live at `.pi/skills/<slug>/SKILL.md`
        alongside the built-in repo skills. When the operator asks
        you to **create** or **modify** a team skill, write the file
        there — Metis syncs it back to the team's DB when the turn
        ends, and the next turn (and every member of the team) sees
        the change.

        - Slug: kebab-case (`code-review`), becomes the directory name.
        - SKILL.md: YAML frontmatter with `name` and `description`,
          then the markdown body that's loaded when pi auto-triggers
          the skill. Supporting files alongside SKILL.md are kept.
        - **Don't modify built-in repo skills.** Their slugs are
          reserved; edits won't persist (the tree is wiped & re-copied
          fresh from the repo every turn) and the team won't see them.
        - Writing the file is the native path and the only way to add
          **supporting files**. For a single-file skill you can instead
          use tools: `metis_list_skills` (every skill — built-in and
          team, with status), `metis_create_skill`, and
          `metis_update_skill` (also toggles `enabled`). Create/update
          act on team skills and need team-admin rights. There's no
          delete tool — ask the operator to remove a skill from the UI.

        ### Installing a public skill

        Append the source to `.pi/skills/.imports` (one per line).
        Don't fetch files yourself with `npx skills add`, `curl`, or
        `bash` — those skip Metis's persistence and GitHub auth.
        Sources: `owner/repo[/path]`, `owner/repo@name`, or a
        github.com URL.

        ## Conventions

        - `uploads/` and `.mcp.json` are projected inputs — rewritten
          each turn. Don't edit them expecting it to stick.
        - Outside the workspace is the operator's host (`Local`) or a
          sandbox wall (`Docker` / `E2b`). The wall holds; don't probe
          it.
        - On identity-bearing connectors (GitHub, etc.), you act *as*
          the operator. Commits, comments, issues — they carry their
          handle. Act like it.
        - In a git working tree: commit author / committer come from
          env, set to the operator's identity when one is wired.
        - Cd into a project under `workspace/`? If it has an
          `AGENTS.md` or `CLAUDE.md`, read it. This file is the Metis
          environment; that one is the project. Both apply. Monorepo
          packages can carry their own — read those when you settle in.
      MD
    end

    private

    # Warm eviction reclaimed workspace/ but kept sessions/ — pi still has
    # its transcript, so this warns about lost files only (cf. the
    # reaped-sandbox history replay below). See Runtime::Docker#workspace_evicted?.
    def workspace_eviction_block
      return "" unless @workspace_evicted

      "\n" + <<~MD
        ## Workspace notice

        Metis reclaimed this conversation's workspace while it was idle.
        Repositories, dependencies, build output, and uncommitted files
        from earlier turns are gone; the conversation transcript remains.
        Verify or recreate files before relying on them.
      MD
    end

    # The sandbox holding pi's transcript was reaped; replay the conversation
    # from the DB so a fresh sandbox keeps the thread. The warning is
    # load-bearing — the workspace files are gone too, so the agent must not
    # act as if anything it wrote earlier still exists on disk.
    def conversation_history_block
      return "" unless @restore_history

      body = restored_transcript
      return "" if body.blank?

      "\n" + <<~MD
        ## Conversation so far

        This conversation resumed after its sandbox was recycled, so your
        working memory and **every file you wrote earlier are gone** — don't
        assume anything you created before still exists on disk; re-read or
        re-create before relying on it. Below is Metis's record of the
        conversation up to now — memory of what was said, not files you can open.

        #{body}
      MD
    end

    # Addresses the agent in the first person — it's reading its own past turns.
    def restored_transcript
      TranscriptDigest.new(@conversation, agent_label: "You").to_s
    end

    # The hosted GitHub/Linear MCP servers take repo/project as per-call
    # params, not a server-side scope — so this prose is the only thing
    # aligning the agent's tool calls to the project's SSOT. Keep it directive.
    def project_context_block
      project = @conversation.project
      return "" unless project

      lines = [ "## Project context", "", "This conversation is about the **#{project.name}** project." ]

      if project.about.present?
        lines.concat([ "", sanitize_about(project.about) ])
      end

      refs = project_refs(project)
      lines.concat([ "", refs ]) if refs

      "\n" + lines.join("\n") + "\n"
    end

    # The attached project's bound external resources, inline — the agent acts
    # on these exact identifiers (GitHub/Linear MCP take repo/project per call),
    # so naming them here is the SSOT alignment. Other projects' refs are
    # fetched on demand via the metis_get_project tool (Agent::HostBridge).
    def project_refs(project)
      parts = []
      parts << "- GitHub repo: `#{project.github_repo}`" if project.github_repo.present?
      parts << "- Linear project: `#{project.linear_project}`" if project.linear_project.present?
      return if parts.empty?

      "Bound resources — use these exact identifiers when acting on the project:\n#{parts.join("\n")}"
    end

    # `about` is freeform: a leading `#` would forge a Metis section
    # heading the agent reads as instructions. Strip leading ATX markers.
    def sanitize_about(text)
      text.to_s.lines.map { |line| line.sub(/\A\s*#+\s*/, "") }.join
    end

    # Lookup-by-mention catalog of the team's projects; the attached one is
    # already spotlighted in #project_context_block, so it's excluded below.
    TEAM_PROJECTS_RENDERED_MAX = 25
    TEAM_PROJECT_ABOUT_TRUNCATE = 140

    def team_projects_block
      projects = team_projects_for_catalog
      return "" if projects.empty?

      lines = [
        "## Projects",
        "",
        "The operator has these projects saved. When their message references " \
        "one — by name, by codebase, or obvious context — reach for the mapping " \
        "without asking. That's the point of saving them."
      ]
      lines << ""
      projects.each { |project| lines << team_project_line(project) }

      "\n" + lines.join("\n") + "\n"
    end

    def team_projects_for_catalog
      scope = @conversation.team.projects.recent
      scope = scope.where.not(id: @conversation.project_id) if @conversation.project_id
      scope.limit(TEAM_PROJECTS_RENDERED_MAX).to_a
    end

    def team_project_line(project)
      line = "- **#{project.name}**"
      if project.about.present?
        about = sanitize_about(project.about).strip.tr("\n", " ").squeeze(" ").truncate(TEAM_PROJECT_ABOUT_TRUNCATE)
        line += " — #{about}" if about.present?
      end
      line
    end

    # Lookup-by-name catalog of the team's saved workflow templates — the
    # counterpart to #team_projects_block. It's how the agent knows what
    # `metis_start_workflow` / `metis_update_workflow` can name, and answers
    # "what workflows do we have?" without a round-trip.
    WORKFLOWS_RENDERED_MAX = 25
    WORKFLOW_DESC_TRUNCATE = 140

    def workflows_block
      workflows = @conversation.team.workflows.includes(:default_project).order(:name).limit(WORKFLOWS_RENDERED_MAX).to_a
      return "" if workflows.empty?

      lines = [
        "## Workflows",
        "",
        "Saved workflow templates for this team. When the operator asks to " \
        "start one, call `metis_start_workflow` (it queues a run for their " \
        "review). Team admins can ask you to create or edit one via " \
        "`metis_create_workflow` / `metis_update_workflow`. Reference a " \
        "workflow by the exact name below.",
        ""
      ]
      workflows.each { |workflow| lines << workflow_line(workflow) }

      "\n" + lines.join("\n") + "\n"
    end

    # Routines — saved prompts that fire on a schedule or webhook event. A
    # short pointer plus the catalog so the agent can answer "what runs
    # automatically?" and manage them by exact name without a round-trip.
    ROUTINES_RENDERED_MAX = 25

    def routines_block
      routines = @conversation.team.routines.order(:name).limit(ROUTINES_RENDERED_MAX).to_a
      header =
        "## Routines\n\n" \
        "Saved prompts that fire on their own — on a schedule or a webhook " \
        "event — each as a normal agent turn. Team admins can ask you to set " \
        "one up, change it, or enable/disable it via `metis_create_routine` / " \
        "`metis_update_routine`; `metis_list_routines` reads them. A routine " \
        "you create starts disabled until the operator enables it. There's no " \
        "delete tool — ask the operator to remove a routine from the UI."

      return "\n" + header + "\n" if routines.empty?

      lines = [ header, "" ] + routines.map { |routine| routine_line(routine) }
      "\n" + lines.join("\n") + "\n"
    end

    def routine_line(routine)
      when_part = routine.schedule? ? "#{routine.cron} (#{routine.timezone})" : "on #{routine.event_type}"
      status = routine.enabled? ? "enabled" : "disabled"
      "- **#{sanitize_inline(routine.name)}** — #{when_part}, #{status}"
    end

    def workflow_line(workflow)
      steps = Array(workflow.steps).size
      parts = [ "#{steps} step#{'s' unless steps == 1}" ]
      gates = workflow.gate_count
      parts << "#{gates} approval gate#{'s' unless gates == 1}" if gates.positive?
      parts << "project: #{workflow.default_project.name}" if workflow.default_project

      line = "- **#{sanitize_inline(workflow.name)}** — #{parts.join(', ')}"
      if workflow.description.present?
        about = sanitize_inline(workflow.description).truncate(WORKFLOW_DESC_TRUNCATE)
        line += " — #{about}" if about.present?
      end
      line += " _(disabled)_" unless workflow.enabled?
      line
    end

    def sanitize_inline(text)
      text.to_s.strip.tr("\r\n", " ").squeeze(" ")
    end

    # Profile context and instructions as their own section, so the agent
    # reads them as standing guidance rather than the user's first prompt.
    def operator_preferences_block
      sections = []
      if user.about_you.present?
        sections << "## About the operator\n\n#{user.about_you}"
      end
      if user.custom_instructions.present?
        sections << "## Operator instructions\n\nStanding instructions from the operator — apply them across the turn:\n\n#{user.custom_instructions}"
      end
      return "" if sections.empty?

      "\n" + sections.join("\n\n") + "\n"
    end

    def runtime_description
      case @runtime_kind
      when "local"   then "`local` — host subprocess; not a security boundary"
      when "docker"  then "`docker` — namespace-isolated container; fresh per turn, your workspace bind-mounted in"
      when "e2b"     then "`e2b` — microVM; same VM resumed each turn via pause/resume"
      when "daytona" then "`daytona` — elastic sandbox; same sandbox resumed each turn via stop/start"
      when "microsandbox" then "`microsandbox` — microVM; fresh per turn, your workspace bind-mounted in"
      end
    end

    def connectors_block
      lines = enabled_connectors.map { |connector| connector_line(connector) }
      return "_None enabled for this team._" if lines.empty?

      lines.join("\n")
    end

    def connector_line(connector)
      app = connector.catalog_app
      auth = connector_auth_description(connector, app)
      name = app&.name || connector.name
      "- **#{name}** (`#{connector.name}`) — #{auth}"
    end

    def connector_auth_description(connector, app)
      credential = connector.credential_for(user)
      return "no credential — you'll see the server, but it may reject calls" if credential.nil?

      if app&.oauth?
        # Mirror McpConfig's gate exactly: claiming OAuth-ready when McpConfig
        # drops the connector makes the agent call tools it doesn't have.
        return "as you (OAuth)" if credential.oauth_ready?

        return "OAuth not yet authorized — connector will be omitted from this turn"
      end

      credential.user_id ? "as you" : "team-shared credential"
    end

    def enabled_connectors
      @conversation.team.connectors.order(:name)
    end

    def user = @conversation.user
    def team = @conversation.team

    # The agent can't reliably name its own model, so hand it the real id
    # to cite. "" when Metis passed no --model (pi uses its own config).
    def model_section
      model = @conversation.configured_model
      return "" if model.blank?

      provider = @conversation.configured_provider
      label = provider.present? && !model.include?("/") ? "#{provider}/#{model}" : model
      "\n- **Model** — `#{label}` — the model you are running as. Cite this " \
        "exact id when you need to name your model; don't guess it."
    end
  end
end
