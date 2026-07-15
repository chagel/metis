# See docs/workflows.md.
class WorkflowRun < ApplicationRecord
  belongs_to :team
  belongs_to :workflow, optional: true            # nil = ad-hoc run
  belongs_to :conversation
  has_many :tasks, -> { order(:position) }, dependent: :destroy

  enum :status, { pending: 0, running: 1, awaiting_approval: 2,
                  completed: 3, failed: 4, cancelled: 5, awaiting_local: 6,
                  queued: 7 }, default: :pending

  scope :active,   -> { where(status: %i[queued pending running awaiting_approval awaiting_local]) }
  # Runs a human (or their machine) must act on for the run to move — a gate,
  # a local claim, or a queued run a person must start.
  scope :awaiting, -> { where(status: %i[queued awaiting_approval awaiting_local]) }

  def active?
    queued? || pending? || running? || awaiting_approval? || awaiting_local?
  end

  # The run-level short reference ("CHEESE-R1G") — the stable key a daemon
  # uses for the run's shared worktree and branch. The R infix keeps it
  # apart from task refs, which carry the same slug.
  def ref
    "#{ref_slug}-R#{id.to_s(36).upcase}"
  end

  def ref_slug
    (workflow&.name || "RUN").parameterize.upcase.first(12)
  end

  # `input` is the run's subject — folded into the first step's prompt here;
  # later steps get it restated (engine step_prompt, bridge claim payload).
  # `visibility` is the launcher's choice from the composer: a team-visible
  # run is openable by any member, who can act on its gates and claim its
  # local steps. A project is mandatory: daemons claim delegated steps per
  # project, so a project-less run could never be auto-claimed.
  #
  # `autostart: false` parks the run as `queued` — built, but not advanced —
  # for a human to start with #launch!. The chat handoff queues; the composer
  # launcher starts immediately.
  def self.start(team:, user:, project:, workflow: nil, steps: nil,
                 input: nil, settings: {}, visibility: :personal,
                 trigger_summary: "Started by you", autostart: true, title: nil)
    raise ArgumentError, "every workflow run needs a project" if project.nil?

    steps ||= workflow&.steps || []
    run = transaction do
      # Every caller must pass a title — auto-titling skips engine-injected
      # `kind: :step_prompt` user messages, so it never names a workflow conversation.
      conversation = user.conversations.create!(
        team: team, project: project, settings: settings || {},
        visibility: visibility, title: title
      )
      run = create!(
        team: team, workflow: workflow, conversation: conversation,
        trigger_summary: trigger_summary, input: input,
        status: (autostart ? :pending : :queued)
      )
      steps.each_with_index do |step, i|
        prompt = step["prompt"] || step[:prompt]
        prompt = [ input, prompt ].compact_blank.join("\n\n") if i.zero? && input.present?
        run.tasks.create!(
          position: i,
          name: step["name"] || step[:name],
          prompt: prompt,
          gate: step["gate"] || step[:gate] || :auto,
          delegated: (step["run"] || step[:run]).to_s == "local"
        )
      end
      run
    end
    WorkflowAdvanceJob.perform_later(run.id) if autostart
    run
  end

  # Start a queued run — the explicit human "go". Hands it to the engine
  # exactly as an immediate start would. No-op once it has left the queue.
  def launch!
    return false unless queued?

    pending!
    WorkflowAdvanceJob.perform_later(id)
    true
  end

  # ChatJob calls this when a turn settles; no-op for a normal chat.
  def self.signal_turn_finished(conversation)
    run = conversation.workflow_run
    WorkflowAdvanceJob.perform_later(run.id) if run&.active?
  end

  def turn_messages
    tasks.includes(:assistant_message).filter_map(&:assistant_message)
  end

  def agent_seconds
    turn_messages.sum { |message| message.duration.to_f }
  end

  def total_cost
    turn_messages.sum { |message| message.cost.to_f }
  end

  # When the run last moved: a turn settling or a gate decision —
  # whichever came later. nil before anything has finished.
  def settled_at
    [ *turn_messages.map(&:finished_at), *tasks.map(&:decided_at) ].compact.max
  end

  def approve_current_gate!(by: nil)
    task = tasks.awaiting_approval.first
    return unless task

    task.update!(status: :completed, approved_by: by, decided_at: Time.current)
    append_review %(#{reviewer(by)} approved "#{task.display_name}"), sender: by
    running!
    WorkflowAdvanceJob.perform_later(id)
  end

  # The local agent reported back — the settle-equivalent for a delegated
  # step, mirroring the post-step shape WorkflowAdvanceJob#settle runs.
  def complete_delegated_task!(task, result:)
    return unless task.delegated? && task.running?

    task.update!(result: result)
    append_local_report(task)

    if task.result_failed?
      task.failed!
      failed!
      WorkflowBroadcaster.new(self).refresh
    elsif task.approval?
      task.awaiting_approval!
      awaiting_approval!
      WorkflowBroadcaster.new(self).refresh
    else
      task.completed!
      running!
      WorkflowAdvanceJob.perform_later(id)
    end
  end

  # The sweeper hit the reclaim cap: every claim on this delegated task
  # went silent. Fails the step and surfaces it — an infrastructure
  # failure re-dispatches silently (Task#reclaim!), but a step that keeps
  # killing its client needs a person, not another cycle.
  def fail_silent_task!(task)
    task.update!(status: :failed, decided_at: Time.current)
    append_local_note %(Gave up on "#{task.display_name}" — every machine that claimed it went silent (#{task.reclaims_count} reclaims).)
    failed!
    WorkflowBroadcaster.new(self).refresh
  end

  # Cancels at a gate, or while a delegated step sits waiting for (or on)
  # a machine — a parked run must always be killable. A result reported
  # after the cancel no-ops (complete_delegated_task! requires running).
  def reject_current_gate!(by: nil)
    task = tasks.awaiting_approval.first || tasks.dispatched.first
    return unless task

    waited_on_local = task.running?
    task.update!(status: :rejected, approved_by: by, decided_at: Time.current)
    append_review((if waited_on_local
      %(#{reviewer(by)} cancelled the run while "#{task.display_name}" waited on a machine)
                   else
      %(#{reviewer(by)} rejected "#{task.display_name}" and cancelled the run)
                   end), sender: by)
    cancelled!
  end

  # Re-run the gated step with the human's feedback; it gates again when
  # done, so the reviewer can iterate instead of only approving. A cloud
  # step re-runs as a turn with the feedback as its prompt; a delegated
  # step re-dispatches to the machine with the feedback folded in — never
  # as a cloud turn (the engine would wait forever for a local report).
  def request_changes!(feedback, by: nil)
    return if feedback.blank?

    task = tasks.awaiting_approval.first
    return unless task

    if task.delegated?
      task.update!(
        **Task::UNCLAIMED_ATTRS,
        status: :running, approved_by: by, dispatched_at: Time.current,
        result: {}, reclaims_count: 0,
        prompt: "#{task.prompt}\n\nRequested changes: #{feedback}"
      )
      append_review "#{reviewer(by)} requested changes — #{feedback}", sender: by
      awaiting_local!
      WorkflowBroadcaster.new(self).refresh
    else
      task.update!(status: :running, approved_by: by)
      running!
      user, assistant = ConversationTurn.start(
        conversation, content: "#{reviewer(by)} requested changes — #{feedback}", kind: :review, sender: by
      )
      task.update!(assistant_message: assistant)
      WorkflowBroadcaster.new(self).append_turn(user, assistant)
    end
  end

  private

  # The delegated step's timeline trace — a plain message, never a turn.
  def append_local_report(task)
    line = task.result_failed? ? "Failed" : "Done"
    line += " on #{task.claimed_label.presence || "a local machine"}"
    line += " — #{task.result_summary}" if task.result_summary
    url = task.result_artifact_urls.first
    line += " → #{url}" if url

    append_local_note(line)
  end

  def append_local_note(content)
    message = conversation.messages.create!(
      role: :assistant, content: content, streaming_status: :done, kind: :local_report
    )
    WorkflowBroadcaster.new(self).append_report(message)
  end

  # A gate decision's timeline trace — a plain message, never a turn.
  def append_review(text, sender: nil)
    message = conversation.messages.create!(
      role: :user, content: text, streaming_status: :done, kind: :review, sender: sender
    )
    WorkflowBroadcaster.new(self).append_report(message)
  end

  def reviewer(by)
    by&.display_label || "The reviewer"
  end
end
