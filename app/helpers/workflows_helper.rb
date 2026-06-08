module WorkflowsHelper
  # Maps a task's status onto the progress-rail node state.
  def wf_step_state(task)
    case task.status
    when "completed"                 then "done"
    when "running"                   then "running"
    when "awaiting_approval"         then "current"
    when "failed", "rejected"        then "failed"
    else                                  "" # pending / skipped
    end
  end

  # The assistant turn a gate is reviewing — the most recent prior step that
  # produced one. nil for a gate with no preceding work.
  def wf_gated_work(run, gate_task)
    run.tasks
       .where("position < ?", gate_task.position)
       .where.not(assistant_message_id: nil)
       .order(:position).last&.assistant_message
  end
end
