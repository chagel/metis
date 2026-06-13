# See docs/workflows.md.
class Workflow < ApplicationRecord
  belongs_to :team
  belongs_to :default_project, class_name: "Project", optional: true
  has_many :workflow_runs, dependent: :nullify

  enum :trigger_source, { manual: 0, webhook: 1, schedule: 2, api: 3 }, default: :manual

  validates :name, presence: true
  validate :default_project_in_team
  validate :steps_have_prompts

  scope :enabled, -> { where(enabled: true) }

  def gate_count
    steps.count { |step| step["gate"] == "approval" }
  end

  private

  def default_project_in_team
    return if default_project_id.blank?
    return if team&.projects&.exists?(default_project_id)

    errors.add(:default_project_id, :not_in_team)
  end

  # A blank prompt would silently become a pause-only checkpoint; require one.
  def steps_have_prompts
    Array(steps).each_with_index do |step, i|
      next if step["prompt"].to_s.strip.present?

      label = step["name"].presence || "Step #{i + 1}"
      errors.add(:steps, :needs_prompt, label: label)
    end
  end
end
