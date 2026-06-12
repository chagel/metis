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
    # A delegated step settles via the pull API's result report, not here
    # — never fail it for lacking an assistant message.
    return :wait if task.delegated?

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
    return dispatch_step(run, task) if task.delegated?
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
    user, assistant = ConversationTurn.start(run.conversation, content: step_prompt(run, task), kind: :step_prompt)
    task.update!(assistant_message: assistant)
    WorkflowBroadcaster.new(run).append_turn(user, assistant)
  end

  # Later steps restate the run input (creation folds it into step 0 only)
  # and the reports of just-prior delegated steps, which never enter the session.
  def step_prompt(run, task)
    subject = (run.input if task.position.positive?)
    reports = run.tasks.completed.where(position: ...task.position).reorder(position: :desc)
                 .take_while(&:delegated?).reverse.map { |prior| delegated_report(prior) }
    [ subject, *reports, task.prompt ].compact_blank.join("\n\n")
  end

  def delegated_report(task)
    line = %(Step "#{task.name}" ran on the user's machine and reported: #{task.result_summary || task.result["status"]})
    urls = task.result_artifact_urls
    line += " (#{urls.join(", ")})" if urls.any?
    line
  end

  # Park the run for a local machine — no turn, no ChatJob. It resumes
  # when a result is reported (WorkflowRun#complete_delegated_task!).
  def dispatch_step(run, task)
    task.update!(status: :running, dispatched_at: Time.current)
    run.awaiting_local!
  end
end
