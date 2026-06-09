# See docs/workflows.md.
class WorkflowRun < ApplicationRecord
  belongs_to :team
  belongs_to :workflow, optional: true            # nil = ad-hoc run
  belongs_to :conversation
  has_many :tasks, -> { order(:position) }, dependent: :destroy

  enum :status, { pending: 0, running: 1, awaiting_approval: 2,
                  completed: 3, failed: 4, cancelled: 5 }, default: :pending

  scope :active,   -> { where(status: %i[pending running awaiting_approval]) }
  scope :awaiting, -> { where(status: :awaiting_approval) }

  def active?
    pending? || running? || awaiting_approval?
  end

  # `input` is the run's subject — folded into the first step's prompt.
  def self.start(team:, user:, workflow: nil, project: nil, steps: nil,
                 input: nil, settings: {}, trigger_summary: "Started by you")
    steps ||= workflow&.steps || []
    run = transaction do
      # No title — auto-titling names each run from its first turn, so runs
      # of one workflow get distinct names.
      conversation = user.conversations.create!(
        team: team, project: project, settings: settings || {}
      )
      run = create!(
        team: team, workflow: workflow, conversation: conversation,
        trigger_summary: trigger_summary
      )
      steps.each_with_index do |step, i|
        prompt = step["prompt"] || step[:prompt]
        prompt = [ input, prompt ].compact_blank.join("\n\n") if i.zero? && input.present?
        run.tasks.create!(
          position: i,
          name: step["name"] || step[:name],
          prompt: prompt,
          gate: step["gate"] || step[:gate] || :auto
        )
      end
      run
    end
    WorkflowAdvanceJob.perform_later(run.id)
    run
  end

  # ChatJob calls this when a turn settles; no-op for a normal chat.
  def self.signal_turn_finished(conversation)
    run = conversation.workflow_run
    WorkflowAdvanceJob.perform_later(run.id) if run&.active?
  end

  def approve_current_gate!(by: nil)
    task = tasks.awaiting_approval.first
    return unless task

    task.update!(status: :completed, approved_by: by, decided_at: Time.current)
    running!
    WorkflowAdvanceJob.perform_later(id)
  end

  def reject_current_gate!(by: nil)
    task = tasks.awaiting_approval.first
    return unless task

    task.update!(status: :rejected, approved_by: by, decided_at: Time.current)
    cancelled!
  end

  # Re-run the gated step with the human's feedback as the prompt; it gates
  # again when done, so the reviewer can iterate instead of only approving.
  def request_changes!(feedback, by: nil)
    return if feedback.blank?

    task = tasks.awaiting_approval.first
    return unless task

    task.update!(status: :running, approved_by: by)
    running!
    user, assistant = ConversationTurn.start(conversation, content: feedback)
    task.update!(assistant_message: assistant)
    WorkflowBroadcaster.new(self).append_turn(user, assistant)
  end
end
