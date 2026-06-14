module BoardHelper
  ACCENT_FOR_COLUMN = {
    running: "run", awaiting_approval: "appr",
    awaiting_local: "local", done: "done"
  }.freeze

  def board_column_label(column)
    t("board.index.columns.#{column}")
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
