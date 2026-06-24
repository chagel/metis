# A raw inbound event from an external provider (GitHub, Linear),
# persisted as the collection substrate for later triggering. Phase 1
# only records — nothing reads these to drive Metis behavior yet. See
# PLAN.md "Inbound webhooks — collect first" and docs/workflows.md Phase 4.
class WebhookEvent < ApplicationRecord
  belongs_to :team
  # Null for account-level events (no repo) or a repo no project binds.
  belongs_to :project, optional: true

  enum :provider, { github: 0, linear: 1 }

  validates :event_type, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_project, ->(project) { where(project: project) }

  def present
    Presenter.new(self)
  end
end
