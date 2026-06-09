# See docs/workflows.md. A delegated task (docs/local-bridge.md) runs on a
# user's enrolled machine instead of as a cloud turn: the engine dispatches
# it, a device claims it off the pull API, and reports a result.
class Task < ApplicationRecord
  belongs_to :workflow_run
  belongs_to :assistant_message, class_name: "Message", optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :claimed_by_device, class_name: "Device", optional: true

  enum :status, { pending: 0, running: 1, awaiting_approval: 2,
                  completed: 3, rejected: 4, failed: 5, skipped: 6 }, default: :pending
  # "none" would clash with ActiveRecord's Model.none, hence auto/approval.
  enum :gate, { auto: 0, approval: 1 }, default: :auto

  validates :position, presence: true

  scope :next_pending, -> { pending.order(:position) }
  # Dispatched and waiting for a device to pull it.
  scope :dispatched, -> { running.where(delegated: true) }
  scope :unclaimed, -> { where(claimed_by_device_id: nil) }

  # Claim the team's next dispatched task for this device, or nil. SKIP
  # LOCKED so two devices polling at once each get a distinct task instead
  # of blocking or double-claiming.
  def self.claim_next_for(device)
    transaction do
      task = joins(:workflow_run)
               .where(workflow_runs: { team_id: device.team_id })
               .dispatched.unclaimed
               .order(:dispatched_at)
               .lock("FOR UPDATE SKIP LOCKED")
               .first
      task&.update!(claimed_by_device: device)
      task
    end
  end

  def log_progress!(entry)
    update!(progress: progress + [ entry ])
  end
end
