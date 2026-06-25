class Project < ApplicationRecord
  NAME_MAX = 80

  # Bound external resources, keyed by provider. github_repo is the
  # "owner/name" the repo lives at on GitHub; linear_project is the Linear
  # project's UUID. Inbound webhooks match a delivery against these to fill
  # WebhookEvent#project (repository.full_name / the event's Linear project).
  store_accessor :external_refs, :github_repo, :linear_project

  validates :name, presence: true,
                    uniqueness: { scope: :team_id },
                    length: { maximum: NAME_MAX },
                    format: { without: /[\r\n]/ }
  validates :github_repo, format: { with: %r{\A[\w.-]+/[\w.-]+\z} }, allow_blank: true
  validates :linear_project, format: { with: /\A[0-9a-f-]{8,}\z/i }, allow_blank: true

  belongs_to :team
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  has_many :conversations, dependent: :nullify

  before_validation :normalize_github_repo
  before_validation :normalize_linear_project
  # Binding a ref retroactively claims its already-collected events — a
  # delivery can land before anyone binds the resource, and those rows
  # would otherwise stay orphaned (project_id nil) forever.
  after_save :adopt_orphan_events, if: :saved_change_to_external_refs?
  # Deleting mid-run would strip the project off the run's conversation,
  # leaving delegated steps unclaimable (daemons claim per project).
  # Prepended so it beats the association's nullify callback.
  before_destroy :forbid_active_runs, prepend: true

  scope :recent, -> { order(updated_at: :desc) }
  # Case-insensitive name match — the agent names a project the way the
  # operator said it, not by id (Agent::WorkflowHandoff).
  scope :named, ->(name) { where("LOWER(name) = LOWER(?)", name.to_s.strip) }
  # The project bound to a GitHub repo, matched case-insensitively against
  # the stored owner/name. Webhooks resolve project_id through this.
  scope :for_github_repo, ->(full_name) {
    where("LOWER(external_refs ->> 'github_repo') = ?", full_name.to_s.downcase)
  }
  # The project bound to a Linear project, matched on the stored UUID.
  scope :for_linear_project, ->(id) {
    where("external_refs ->> 'linear_project' = ?", id.to_s)
  }

  private

  # Forgive a pasted URL or trailing .git, store a bare lowercased
  # owner/name (GitHub treats repo names case-insensitively), nil when blank.
  def normalize_github_repo
    self.github_repo = github_repo.to_s.strip
      .sub(%r{\Ahttps?://github\.com/}i, "")
      .sub(/\.git\z/i, "")
      .downcase.presence
  end

  def normalize_linear_project
    self.linear_project = linear_project.to_s.strip.downcase.presence
  end

  def adopt_orphan_events
    adopt_github_orphans if github_repo.present?
    adopt_linear_orphans if linear_project.present?
  end

  def adopt_github_orphans
    WebhookEvent.where(team_id: team_id, project_id: nil, provider: :github)
                .where("LOWER(payload -> 'repository' ->> 'full_name') = ?", github_repo)
                .update_all(project_id: id)
  end

  # The project id sits at different paths by event type (data.id for a
  # Project event, data.projectId / data.project.id elsewhere) — match any.
  def adopt_linear_orphans
    WebhookEvent.where(team_id: team_id, project_id: nil, provider: :linear)
                .where("payload -> 'data' ->> 'id' = :id OR payload -> 'data' ->> 'projectId' = :id " \
                       "OR payload -> 'data' -> 'project' ->> 'id' = :id", id: linear_project)
                .update_all(project_id: id)
  end

  def forbid_active_runs
    return unless WorkflowRun.active.where(conversation_id: conversations.select(:id)).exists?

    errors.add(:base, :has_active_runs)
    throw :abort
  end
end
