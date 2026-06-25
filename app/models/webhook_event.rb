# A raw inbound provider event (GitHub, Linear), collected for later
# triggering — nothing reads these to drive behavior yet (PLAN.md Phase 1).
class WebhookEvent < ApplicationRecord
  belongs_to :team
  # Null for account-level events (no repo) or a repo no project binds.
  belongs_to :project, optional: true

  enum :provider, { github: 0, linear: 1 }

  validates :event_type, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_project, ->(project) { where(project: project) }

  def present
    (linear? ? Presenter::Linear : Presenter).new(self)
  end
end
