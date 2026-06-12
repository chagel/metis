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
    replace("workflow_gate", "workflow_runs/gate")
    replace("composer", "workflow_runs/run_status")
    refresh_run_page
    refresh_sidebar
  end

  # An engine-started turn has no controller to append its message rows (the
  # chat path does that in create.turbo_stream), so do it here — else
  # ChatBroadcaster's streaming has no DOM to land in until a refresh.
  # The run page rides along so the step card flips to running.
  def append_turn(user_message, assistant_message)
    append_message(user_message, forkable: false)
    append_message(assistant_message, forkable: true)
    refresh_run_page
  end

  # A delegated step's report line (WorkflowRun#append_local_report).
  def append_report(message)
    append_message(message, forkable: false)
    refresh_run_page
  end

  # The header stats ride in workflow_meta, so it refreshes with the timeline.
  def refresh_run_page
    replace("workflow_timeline", "workflow_runs/timeline", conversation: @conversation)
    replace("workflow_meta", "workflow_runs/meta")
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

  # Every member's stream for a team-visible run, only the owner's for a
  # personal one — a private run's status must not transit teammates'
  # streams. A no-op for anyone whose row isn't currently rendered.
  def refresh_sidebar
    members = @conversation.visibility_team? ? @conversation.team.members : [ @conversation.user ]
    members.each do |member|
      Turbo::StreamsChannel.broadcast_replace_to(
        member,
        target: dom_id(@conversation, :wf_status),
        partial: "workflow_runs/sidebar_pill",
        locals: { conversation: @conversation, run: @run }
      )
    end
  end
end
