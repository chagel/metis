# The workflow engine: a thin state machine that decides whether — and with
# what prompt — to fire the next turn. It never decides what the agent does
# inside a turn (see docs/workflows.md). Re-entered after each turn settles
# (via WorkflowRun.signal_turn_finished) and after a gate is approved.
#
# A step runs its prompt as a turn, and `approval` means "pause for review
# *after* that turn" — so a gated step does its work, then waits. A step
# with no prompt is a pure checkpoint (gate) or a no-op (auto, skipped).
class WorkflowAdvanceJob < ApplicationJob
  queue_as :default

  def perform(workflow_run_id)
    run = WorkflowRun.find(workflow_run_id)
    return unless run.active?

    case settle(run)
    when :wait
      return
    when :gate, :failed
      WorkflowBroadcaster.new(run).refresh
      return
    end

    advance(run)
    WorkflowBroadcaster.new(run).refresh
  end

  private

  # Resolve the step whose turn is in flight.
  #   :continue — its turn finished cleanly (or none was running); advance
  #   :gate     — it finished and asks for approval; pause here
  #   :failed   — its turn errored/canceled; the run is dead
  #   :wait     — still streaming; do nothing until the next signal
  def settle(run)
    task = run.tasks.running.first
    return :continue unless task

    case task.assistant_message&.streaming_status
    when "done"
      if task.approval?
        task.awaiting_approval!
        run.awaiting_approval!
        :gate
      else
        task.completed!
        :continue
      end
    when "errored", "canceled", nil
      task.failed!
      run.failed!
      :failed
    else
      :wait
    end
  end

  def advance(run)
    task = run.tasks.next_pending.first
    return run.completed! if task.nil?

    if task.prompt.blank?
      # A pure checkpoint pauses with no work; an empty auto step is a no-op.
      if task.approval?
        task.awaiting_approval!
        run.awaiting_approval!
      else
        task.skipped!
        advance(run)
      end
    else
      start_step(run, task)
    end
  end

  def start_step(run, task)
    task.running!
    run.running! unless run.running?
    user, assistant = ConversationTurn.start(run.conversation, content: task.prompt, workflow_generated: true)
    task.update!(assistant_message: assistant)
    WorkflowBroadcaster.new(run).append_turn(user, assistant)
  end
end
