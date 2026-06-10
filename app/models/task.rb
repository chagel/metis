# See docs/workflows.md. A delegated task (docs/local-bridge.md) runs on the
# user's own machine instead of as a cloud turn: the engine dispatches it, a
# local agent claims it off the pull API, and reports a result.
class Task < ApplicationRecord
  belongs_to :workflow_run
  belongs_to :assistant_message, class_name: "Message", optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :claimed_by_user, class_name: "User", optional: true

  enum :status, { pending: 0, running: 1, awaiting_approval: 2,
                  completed: 3, rejected: 4, failed: 5, skipped: 6 }, default: :pending
  # "none" would clash with ActiveRecord's Model.none, hence auto/approval.
  enum :gate, { auto: 0, approval: 1 }, default: :auto

  validates :position, presence: true

  scope :next_pending, -> { pending.order(:position) }
  # Dispatched and waiting for a local agent to pull it.
  scope :dispatched, -> { running.where(delegated: true) }
  # Both nil: tasks claimed before claimed_by_user existed must not
  # re-enter the queue mid-deploy.
  scope :unclaimed, -> { where(claimed_by_user_id: nil, claimed_by: nil) }
  scope :delegated_for, ->(user) {
    joins(:workflow_run).where(delegated: true, workflow_runs: { team_id: user.team_ids })
  }
  scope :claimable_by, ->(user) { delegated_for(user).running.unclaimed }

  # FIFO claim (or by id/ref) across the user's teams; nil when nothing is
  # claimable. SKIP LOCKED so concurrent pollers each get a distinct task
  # instead of blocking or double-claiming.
  def self.claim_next_for(user, client: nil, id: nil)
    transaction do
      scope = claimable_by(user)
      scope = scope.where(id: dereference(id)) if id.present?
      task = scope.order(:dispatched_at).lock("FOR UPDATE SKIP LOCKED").first
      task&.update!(claimed_by_user: user, claimed_by: client.presence)
      task
    end
  end

  # The Sentry-style short reference ("CHEESE-1G") clients quote instead
  # of a bare id. Derived from the id, so it needs no column and never
  # collides; dereference accepts either form.
  def ref
    slug = (workflow_run.workflow&.name || "RUN").parameterize.upcase.first(12)
    "#{slug}-#{id.to_s(36).upcase}"
  end

  def self.dereference(ref_or_id)
    value = ref_or_id.to_s.strip
    value.include?("-") ? value.split("-").last.to_i(36) : value.to_i
  end

  def log_progress!(entry)
    update!(progress: progress + [ entry ])
  end

  def final_step?
    workflow_run.tasks.where("position > ?", position).none?
  end

  # Who's working this delegated task, for timelines: "Bob's Apollo".
  def claimed_label
    return claimed_by unless claimed_by_user

    "#{claimed_by_user.display_label}'s #{claimed_by.presence || "machine"}"
  end

  # The result jsonb ({ "status", "summary", "artifacts" }) is read only
  # through these.
  def result_failed?
    result["status"] == "failed"
  end

  def result_summary
    result["summary"].presence
  end

  def result_artifact_urls
    Array(result["artifacts"]).filter_map { |a| a["url"] }
  end
end
