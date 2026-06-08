# See docs/workflows.md. One execution of a Workflow. Owns the Conversation
# that is its execution substrate (transcript, sandbox scope); its Tasks are
# the steps. A gate is a turn boundary the engine won't cross until approved.
class WorkflowRun < ApplicationRecord
  belongs_to :team
  belongs_to :workflow, optional: true            # nil = ad-hoc run
  belongs_to :conversation
  has_many :tasks, -> { order(:position) }, dependent: :destroy

  enum :status, { pending: 0, running: 1, awaiting_approval: 2,
                  completed: 3, failed: 4, cancelled: 5 }, default: :pending

  scope :active,   -> { where(status: %i[pending running awaiting_approval]) }
  scope :awaiting, -> { where(status: :awaiting_approval) }
end
