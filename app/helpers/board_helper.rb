module BoardHelper
  ACCENT_FOR_COLUMN = {
    running: "run", awaiting_approval: "appr",
    awaiting_local: "local", done: "done"
  }.freeze

  def board_column_label(column)
    t("board.index.columns.#{column}")
  end

  # The current filters as a query hash, with one facet overridable.
  # Defaults read the controller's assigns; only non-default facets are
  # encoded so a pristine board has a clean URL.
  def board_filter_query(scope: @scope, done: @done, projects: @project_ids)
    query = {}
    query[:scope] = scope unless scope == :all
    query[:done] = done unless done == "24h"
    query[:projects] = projects if projects.present?
    query
  end

  # A board URL carrying the current filters with one facet overridden.
  def board_filter_path(**overrides)
    board_path(board_filter_query(**overrides))
  end

  def board_scope_active?(scope)
    @scope == scope
  end

  # Mine / Needs me are toggles: activating the live one clears back to the
  # default (all) scope.
  def board_scope_toggle_path(scope)
    board_filter_path(scope: board_scope_active?(scope) ? :all : scope)
  end

  def board_done_active?(done)
    @done == done
  end

  def board_project_selected?(project)
    @project_ids.include?(project.id)
  end

  # The label on the projects filter button: all projects (none selected),
  # the one selected name, or a count.
  def board_projects_label
    case @project_ids.size
    when 0 then t("board.filters.projects.all")
    when 1 then @projects.find { |project| project.id == @project_ids.first }&.name
    else        t("board.filters.projects.count", count: @project_ids.size)
    end
  end

  # The accent class for a card, by column — except a terminal run in the
  # Done column that failed/cancelled gets the danger accent.
  def board_card_accent(run, column)
    return "fail" if column == :done && !run.completed?

    ACCENT_FOR_COLUMN.fetch(column)
  end

  def board_card_title(run)
    run.conversation.display_title.presence || truncate(run.input.to_s, length: 80)
  end

  # The run's short reference, from its first step; nil for an empty run.
  def board_card_ref(run)
    run.tasks.first&.ref
  end

  def board_workflow_name(run)
    run.workflow&.name || t("board.index.card.workflow")
  end

  # [completed_count, total] for the "step N/M" label.
  def board_step_counts(run)
    total = run.tasks.size
    done = run.tasks.count(&:completed?)
    current = run.active? ? [ done + 1, total ].min : total
    [ current, total ]
  end

  # The step a running card is on, for its label; nil when none is active.
  def board_current_step(run)
    run.tasks.find { |task| !task.completed? } || run.tasks.last
  end

  # Compact single-unit "last seen" label for a machine heartbeat.
  def board_seen_ago(time)
    return t("board.actors.never") if time.blank?

    seconds = (Time.current - time).to_i
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600
    return "#{seconds / 3600}h" if seconds < 86_400

    "#{seconds / 86_400}d"
  end

  # The pip fill class mirroring the timeline's step states.
  def board_pip_class(task)
    case wf_step_state(task)
    when "done"             then "f"
    when "running", "current" then "c"
    else                         ""
    end
  end
end
