# A raw inbound provider event (GitHub, Linear), collected and then fanned
# out to the team's matching event routines (docs/routines.md).
class WebhookEvent < ApplicationRecord
  belongs_to :team
  # Null for account-level events (no repo) or a repo no project binds.
  belongs_to :project, optional: true

  enum :provider, { github: 0, linear: 1 }

  validates :event_type, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_project, ->(project) { where(project: project) }

  after_create_commit :dispatch_routines

  def present
    (linear? ? Presenter::Linear : Presenter).new(self)
  end

  private

  def dispatch_routines
    RoutineDispatchJob.perform_later(id)
  end
end
