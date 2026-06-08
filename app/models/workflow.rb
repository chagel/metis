# See docs/workflows.md. A saved, multi-step recipe the agent runs on its
# own, pausing at gates for human approval. The template; WorkflowRun is
# an execution of it.
class Workflow < ApplicationRecord
  belongs_to :team
  has_many :workflow_runs, dependent: :nullify

  enum :trigger_source, { manual: 0, webhook: 1, schedule: 2, api: 3 }, default: :manual

  validates :name, presence: true

  scope :enabled, -> { where(enabled: true) }
end
