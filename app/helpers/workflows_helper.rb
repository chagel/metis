module WorkflowsHelper
  def wf_run_status_label(run)
    case run.status
    when "pending", "running" then "Running"
    when "awaiting_local"     then wf_local_label(run)
    when "awaiting_approval"  then "Review"
    when "completed"          then "Completed"
    when "failed"             then "Failed"
    when "cancelled"          then "Cancelled"
    end
  end

  # Viewer-neutral: the run chat is team-visible, so "your machine" would
  # lie to everyone but the claimer.
  def wf_local_label(run)
    claimer = run.tasks.dispatched.first&.claimed_by_user
    claimer ? "On #{claimer.display_label}'s machine" : "Waiting for a machine"
  end

  def wf_step_state(task)
    case task.status
    when "completed"                 then "done"
    when "running"                   then "running"
    when "awaiting_approval"         then "current"
    when "failed", "rejected"        then "failed"
    else                                  "" # pending / skipped
    end
  end

  def wf_turn_window(message)
    return unless message&.started_at && message.finished_at

    "#{message.started_at.strftime("%-l:%M:%S")} → #{message.finished_at.strftime("%-l:%M:%S %p")}"
  end

  def wf_trigger_stamp(time)
    time.strftime("%b %-d · %-l:%M:%S %p")
  end

  # "44s", "4m 44s", "6h 2m" — for the timeline's totals and gate pauses.
  def wf_compact_duration(seconds)
    return "—" if seconds.to_f <= 0
    return "#{seconds.round}s" if seconds < 60

    minutes, rest = seconds.divmod(60)
    return "#{minutes.to_i}m #{rest.round}s" if minutes < 60

    hours, minutes = minutes.divmod(60)
    "#{hours.to_i}h #{minutes.to_i}m"
  end

  # The turn a gate reviews: the gate step's own, else the most recent prior
  # step that produced one.
  def wf_gated_work(run, gate_task)
    gate_task.assistant_message ||
      run.tasks
         .where("position < ?", gate_task.position)
         .where.not(assistant_message_id: nil)
         .order(:position).last&.assistant_message
  end
end
