class Project < ApplicationRecord
  NAME_MAX = 80

  validates :name, presence: true,
                    uniqueness: { scope: :team_id },
                    length: { maximum: NAME_MAX },
                    format: { without: /[\r\n]/ }

  belongs_to :team
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  has_many :conversations, dependent: :nullify

  # Deleting mid-run would strip the project off the run's conversation,
  # leaving delegated steps unclaimable (daemons claim per project).
  # Prepended so it beats the association's nullify callback.
  before_destroy :forbid_active_runs, prepend: true

  scope :recent, -> { order(updated_at: :desc) }

  private

  def forbid_active_runs
    return unless WorkflowRun.active.where(conversation_id: conversations.select(:id)).exists?

    errors.add(:base, :has_active_runs)
    throw :abort
  end
end
