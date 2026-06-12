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
  # Claimed and silent past the cutoff — reclaim candidates. Progress is
  # the heartbeat: claim/events stamp last_reported_at, so a task whose
  # client keeps posting never matches. Unclaimed tasks never match —
  # offline is just latency, only a held claim can go stale.
  scope :silent_claims, ->(cutoff) {
    dispatched.where.not(claimed_by_user_id: nil).where(last_reported_at: ..cutoff)
  }
  scope :in_project, ->(name) {
    joins(workflow_run: { conversation: :project })
      .where("LOWER(projects.name) = ?", name.to_s.downcase)
  }

  # FIFO claim (or by id/ref, or scoped to one project) across the user's
  # teams; nil when nothing is claimable. SKIP LOCKED so concurrent
  # pollers each get a distinct task instead of blocking or double-claiming.
  def self.claim_next_for(user, client: nil, id: nil, project: nil)
    task = transaction do
      scope = claimable_by(user)
      scope = scope.where(id: dereference(id)) if id.present?
      scope = scope.in_project(project) if project.present?
      found = scope.order(:dispatched_at).lock("FOR UPDATE SKIP LOCKED").first
      found&.update!(claimed_by_user: user, claimed_by: client.presence,
                     claimed_at: Time.current, last_reported_at: Time.current)
      found
    end
    # The run page shows who holds the step ("On M's Apollo") — push the
    # flip live, after commit, for every claim surface alike.
    WorkflowBroadcaster.new(task.workflow_run).refresh if task
    task
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
    update!(progress: progress + [ entry ], last_reported_at: Time.current)
    WorkflowBroadcaster.new(workflow_run).refresh
  end

  # Whether a client may still post events/results against this task.
  # False once the run settled it (cancelled, completed) or the sweeper
  # reclaimed the claim — the claim that holds the task wins, not the
  # last writer.
  def reportable?
    delegated? && running? && claimed_by_user_id.present?
  end

  # Return a silent claim to the unclaimed pool; the run stays
  # awaiting_local and the next pull picks the task up.
  def reclaim!(label = claimed_label)
    update!(
      claimed_by: nil, claimed_by_user: nil, claimed_at: nil, last_reported_at: nil,
      reclaims_count: reclaims_count + 1,
      progress: progress + [ { "kind" => "reclaim",
                               "text" => "#{label} went silent — returned to the queue" } ]
    )
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

  # Which agent/model the local machine actually ran — self-reported by
  # the daemon from the agent's own event stream; the machine owner picks
  # the model, Metis only acknowledges it.
  def result_agent
    result["agent"].presence
  end

  def result_model
    result["model"].presence
  end
end
