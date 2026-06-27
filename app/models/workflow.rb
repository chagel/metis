# See docs/workflows.md.
class Workflow < ApplicationRecord
  belongs_to :team
  belongs_to :default_project, class_name: "Project", optional: true
  has_many :workflow_runs, dependent: :nullify

  NAME_MAX = 80

  enum :trigger_source, { manual: 0, webhook: 1, schedule: 2, api: 3 }, default: :manual

  normalizes :name, with: ->(name) { name.to_s.strip }

  validates :name, presence: true,
                   uniqueness: { scope: :team_id, case_sensitive: false },
                   length: { maximum: NAME_MAX },
                   format: { without: /[\r\n]/ }
  validate :default_project_in_team
  validate :steps_have_prompts

  scope :enabled, -> { where(enabled: true) }
  # Case-insensitive name match — the agent passes a workflow name the way
  # the operator said it, not an id (Agent::WorkflowHandoff).
  scope :named, ->(name) { where("LOWER(name) = LOWER(?)", name.to_s.strip).order(:id) }

  # Normalizes editor/agent step rows into the stored shape, shared by the
  # form (WorkflowsController) and the agent (Agent::WorkflowAuthoring). A
  # `kind: "break"` row is an editor-only marker that folds into the previous
  # step as `gate: approval`; blank rows and leading breaks are dropped.
  def self.normalize_steps(rows)
    rows = rows.values if rows.respond_to?(:values)
    Array(rows).each_with_object([]) do |row, steps|
      if field(row, :kind) == "break"
        steps.last&.store("gate", "approval")
        next
      end

      name = field(row, :name).strip
      prompt = field(row, :prompt).strip
      next if name.blank? && prompt.blank?

      steps << {
        "name" => name,
        "prompt" => prompt,
        "gate" => (field(row, :gate) == "approval" ? "approval" : "auto"),
        "run" => (field(row, :run) == "local" ? "local" : "cloud")
      }
    end
  end

  # Reads a key from a plain hash or ActionController::Parameters, symbol or
  # string, as a string.
  def self.field(row, key)
    (row[key.to_sym] || row[key.to_s]).to_s
  end
  private_class_method :field

  def gate_count
    steps.count { |step| step["gate"] == "approval" }
  end

  # A friendly default title for a run of this workflow, when there's no
  # better subject to name it from (Agent::WorkflowHandoff, the launcher).
  def run_title
    "#{name} workflow"
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
