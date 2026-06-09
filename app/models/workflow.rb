# See docs/workflows.md. A saved, multi-step recipe the agent runs on its
# own, pausing at gates for human approval. The template; WorkflowRun is
# an execution of it.
class Workflow < ApplicationRecord
  belongs_to :team
  belongs_to :default_project, class_name: "Project", optional: true
  has_many :workflow_runs, dependent: :nullify

  enum :trigger_source, { manual: 0, webhook: 1, schedule: 2, api: 3 }, default: :manual

  validates :name, presence: true
  validate :default_project_in_team

  scope :enabled, -> { where(enabled: true) }

  def gate_count
    steps.count { |step| step["gate"] == "approval" }
  end

  private

  def default_project_in_team
    return if default_project_id.blank?
    return if team&.projects&.exists?(default_project_id)

    errors.add(:default_project_id, "is not in this team")
  end
end
