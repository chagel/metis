# Pushes a workflow run's live DOM to the conversation's stream — the rail,
# the gate card, and the composer slot — plus the owner's sidebar pill.
# Re-renders all regions from current state on every transition: small
# partials, always correct. Mirrors ChatBroadcaster's division of labor.
class WorkflowBroadcaster
  include ActionView::RecordIdentifier

  def initialize(run)
    @run = run
    @conversation = run.conversation
  end

  def refresh
    @run.tasks.reload
    replace("workflow_rail", "workflow_runs/rail")
    replace("workflow_gate", "workflow_runs/gate")
    replace("composer", "workflow_runs/run_status")
    refresh_sidebar
  end

  # Append an engine-started turn's message rows to the live thread. The
  # normal chat path does this in the controller's create.turbo_stream; an
  # engine-started turn has no controller, so ChatBroadcaster's streaming
  # would otherwise have no DOM to land in until a refresh.
  def append_turn(user_message, assistant_message)
    append_message(user_message, forkable: false)
    append_message(assistant_message, forkable: true)
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

  # On the owner's own stream, like ChatBroadcaster's running dot — a no-op
  # if their sidebar row isn't currently rendered with the pill.
  def refresh_sidebar
    Turbo::StreamsChannel.broadcast_replace_to(
      @conversation.user,
      target: dom_id(@conversation, :wf_status),
      partial: "workflow_runs/sidebar_pill",
      locals: { conversation: @conversation, run: @run }
    )
  end
end
