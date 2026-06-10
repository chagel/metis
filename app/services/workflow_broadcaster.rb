# A run's live DOM (rail, gate, composer slot, sidebar pill). Re-renders
# every region from current state on each transition. Mirrors ChatBroadcaster.
class WorkflowBroadcaster
  include ActionView::RecordIdentifier

  def initialize(run)
    @run = run
    @conversation = run.conversation
  end

  def refresh
    @run.tasks.reload
    replace("workflow_meta", "workflow_runs/meta")
    replace("workflow_rail", "workflow_runs/rail")
    replace("workflow_gate", "workflow_runs/gate")
    replace("composer", "workflow_runs/run_status")
    refresh_sidebar
  end

  # An engine-started turn has no controller to append its message rows (the
  # chat path does that in create.turbo_stream), so do it here — else
  # ChatBroadcaster's streaming has no DOM to land in until a refresh.
  def append_turn(user_message, assistant_message)
    append_message(user_message, forkable: false)
    append_message(assistant_message, forkable: true)
  end

  # A delegated step's report line (WorkflowRun#append_local_report).
  def append_report(message)
    append_message(message, forkable: false)
  end

  private

  def append_message(message, forkable:)
    Turbo::StreamsChannel.broadcast_append_to(
      @conversation, target: "messages",
      partial: "messages/message", locals: { message: message, forkable: forkable }
    )
  end

  def replace(target, partial, extra = {})
    Turbo::StreamsChannel.broadcast_replace_to(
      @conversation, target: target, partial: partial, locals: { run: @run }.merge(extra)
    )
  end

  # Owner's stream — a no-op if their sidebar row isn't currently rendered.
  def refresh_sidebar
    Turbo::StreamsChannel.broadcast_replace_to(
      @conversation.user,
      target: dom_id(@conversation, :wf_status),
      partial: "workflow_runs/sidebar_pill",
      locals: { conversation: @conversation, run: @run }
    )
  end
end
