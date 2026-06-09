# The workflow engine: a thin state machine that sequences turns and gates.
# It decides whether — and with what prompt — to fire the next turn, never
# what the agent does inside one. See docs/workflows.md.
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

  # Resolve the running step's turn: :continue / :gate / :failed / :wait.
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
    return start_step(run, task) if task.prompt.present?

    # Blank prompt (only via direct runs — authored steps require one): an
    # approval step is a pure checkpoint, an auto step is a no-op.
    if task.approval?
      task.awaiting_approval!
      run.awaiting_approval!
    else
      task.skipped!
      advance(run)
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
