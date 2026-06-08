# See docs/workflows.md. One step of a WorkflowRun. Runs as a single agent
# turn (gate: none) or pauses for human approval (gate: approval).
# #assistant_message links to the turn it produced — the audit trail.
class Task < ApplicationRecord
  belongs_to :workflow_run
  belongs_to :assistant_message, class_name: "Message", optional: true
  belongs_to :approved_by, class_name: "User", optional: true

  enum :status, { pending: 0, running: 1, awaiting_approval: 2,
                  completed: 3, rejected: 4, failed: 5, skipped: 6 }, default: :pending
  # auto = runs as an agent turn; approval = pauses for a human (gate).
  # "none" would clash with ActiveRecord's Model.none relation method.
  enum :gate, { auto: 0, approval: 1 }, default: :auto

  validates :position, presence: true

  scope :next_pending, -> { pending.order(:position) }
end
