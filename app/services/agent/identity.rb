module Agent
  # Renders the per-turn `AGENTS.md` that boots the agent. See
  # `docs/agent-identity.md` for the design.
  class Identity
    FILENAME = "AGENTS.md".freeze

    def initialize(conversation, runtime_kind, restore_history: false)
      @conversation = conversation
      @runtime_kind = runtime_kind.to_s
      @restore_history = restore_history
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

        #{conversation_history_block}
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

    HISTORY_CHAR_BUDGET = 12_000
    HISTORY_MESSAGE_TRUNCATE = 2_000

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

    # Quote the most recent turns within budget, walking newest-first so a long
    # reaped conversation only decrypts the messages it keeps; mark how many
    # older ones were dropped.
    def restored_transcript
      rows = @conversation.replayable_history.reverse_order
      kept = []
      total = 0
      truncated = false
      rows.each do |message|
        line = transcript_quote(message)
        next unless line
        if kept.any? && total + line.length > HISTORY_CHAR_BUDGET
          truncated = true
          break
        end

        kept.unshift(line)
        total += line.length
      end

      if truncated
        omitted = rows.size - kept.size
        kept.unshift("_[#{omitted} earlier message#{'s' unless omitted == 1} omitted]_")
      end
      kept.join("\n\n")
    end

    # The `> ` framing reads as quoted transcript and keeps a markdown heading
    # in the content from manufacturing a Metis section.
    def transcript_quote(message)
      text = message.content.to_s.strip
      return nil if text.blank?

      speaker = message.user? ? "Operator" : "You"
      quoted = text.truncate(HISTORY_MESSAGE_TRUNCATE).each_line.map { |line| "> #{line.chomp}" }.join("\n")
      "**#{speaker}:**\n#{quoted}"
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

      "\n" + lines.join("\n") + "\n"
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
