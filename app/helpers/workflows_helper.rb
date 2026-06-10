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
