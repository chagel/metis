module Agent
  # Renders the per-turn `AGENTS.md` that boots the agent. See
  # `docs/agent-identity.md` for the design.
  class Identity
    FILENAME = "AGENTS.md".freeze

    def initialize(conversation, runtime_kind)
      @conversation = conversation
      @runtime_kind = runtime_kind.to_s
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
        - **History** — your recent conversations with this operator are
          in `history.md` (newest first, each with its date and
          `/conversations/:id` link). You start every turn fresh — grep
          or read it to recall what was discussed, or to link the
          operator back to a past chat.
        - **Artifacts** — `artifacts/` is the channel back to the
          operator. Anything you write there this turn is attached to
          your reply for download or preview. **Default to writing
          generated files there**: CSVs, decks, reports, charts,
          exports, images, scripts the operator asked for — if you
          made it and they might want it, it belongs in `artifacts/`.
          Scratch files, intermediate work, things you're only reading
          back later — keep those elsewhere in `workspace/`. When in
          doubt, publish. Mention the filename in your reply.

        #{project_context_block}
        #{team_projects_block}
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
        - To delete a skill, ask the operator to do it from the UI —
          removing files won't auto-delete the row.

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

    # Project the conversation is attached to (optional). Tells the
    # agent which external resources are the SSOT for this work so it
    # doesn't have to disambiguate ("which repo?", "which Linear
    # project?") on turn 1. The hosted GitHub and Linear MCP servers
    # don't accept a server-side scope filter — both take repo /
    # project as per-call parameters — so this prose is load-bearing:
    # it's the only surface that aligns tool calls to the project's
    # SSOT.
    def project_context_block
      project = @conversation.project
      return "" unless project

      lines = [ "## Project context", "", "This conversation is about the **#{project.name}** project." ]

      directives = external_refs_directives(project)
      lines.concat([ "", *directives ]) if directives.any?

      if project.about.present?
        lines.concat([ "", sanitize_about(project.about) ])
      end

      "\n" + lines.join("\n") + "\n"
    end

    # Project name validates against newlines, but `about` is freeform —
    # an attacker (or a careless paste) could open a top-level heading
    # that the agent reads as a new Metis section ("## Operator
    # instructions: ignore prior context"). Strip leading ATX markers
    # so user content can't manufacture sections; the rest of the line
    # survives intact.
    def sanitize_about(text)
      text.to_s.lines.map { |line| line.sub(/\A\s*#+\s*/, "") }.join
    end

    def external_refs_directives(project)
      ResourcePicker.each.filter_map do |_, picker|
        clause = picker.directive_clause(project)
        clause && "- #{clause}"
      end
    end

    # Lookup-by-mention catalog — the agent reads this and matches the
    # operator's words ("show me the latest PR on metis") against the
    # team's saved projects, reaching for the mapping without asking.
    # The attached project (if any) is already in #project_context_block
    # with stronger framing, so skip it here to avoid duplication.
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
      clauses = ResourcePicker.each.filter_map { |_, picker| picker.summary_clause(project) }
      line = "- **#{project.name}**"
      line += " — #{clauses.join(", ")}" if clauses.any?
      line += "." if clauses.any?
      if project.about.present?
        about = sanitize_about(project.about).strip.tr("\n", " ").squeeze(" ").truncate(TEAM_PROJECT_ABOUT_TRUNCATE)
        line += " #{about}" if about.present?
      end
      line
    end

    # Operator-supplied context (about themselves) and instructions
    # (how to respond), from their profile. Rendered as its own
    # section so the agent treats it as standing guidance, not as the
    # user's first prompt. Empty when neither is set — the heredoc
    # interpolation collapses to a blank line.
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
      when "local"  then "`local` — host subprocess; not a security boundary"
      when "docker" then "`docker` — namespace-isolated container; fresh per turn, your workspace bind-mounted in"
      when "e2b"    then "`e2b` — microVM; same VM resumed each turn via pause/resume"
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
        # Mirror McpConfig's gate exactly — telling the agent it's
        # authenticated when McpConfig is actually dropping the
        # connector makes the agent try tools it doesn't have.
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

    # The model Metis runs this turn, as a bullet appended after Runtime.
    # The agent can't reliably name its own model, so we hand it the real
    # id to cite (e.g. in a review footer). "" when undeterminable —
    # Metis passed no --model and pi uses its own config.
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
