# The workflow engine: a thin state machine that decides whether — and with
# what prompt — to fire the next turn. It never decides what the agent does
# inside a turn (see docs/workflows.md). Re-entered after each turn settles
# (via WorkflowRun.signal_turn_finished) and after a gate is approved.
class WorkflowAdvanceJob < ApplicationJob
  queue_as :default

  def perform(workflow_run_id)
    run = WorkflowRun.find(workflow_run_id)
    return unless run.active?

    if settle_or_wait(run)
      WorkflowBroadcaster.new(run).refresh if run.failed?
      return
    end

    advance(run)
    WorkflowBroadcaster.new(run).refresh
  end

  private

  # Resolve the step whose turn we started. Returns true ("stop") when the
  # turn is still in flight or the run just failed — otherwise the prior
  # step is complete and we may advance.
  def settle_or_wait(run)
    task = run.tasks.running.first
    return false unless task

    case task.assistant_message&.streaming_status
    when "done"
      task.completed!
      false
    when "errored", "canceled", nil
      task.failed!
      run.failed!
      true
    else # pending / streaming — wait for the next signal
      true
    end
  end

  def advance(run)
    task = run.tasks.next_pending.first
    if task.nil?
      run.completed!
    elsif task.approval?
      task.awaiting_approval!
      run.awaiting_approval!   # Phase 2 broadcasts the gate card + notifies
    else
      start_step(run, task)
    end
  end

  def start_step(run, task)
    task.running!
    run.running! unless run.running?
    _user, assistant = ConversationTurn.start(run.conversation, content: task.prompt)
    task.update!(assistant_message: assistant)
  end
end
