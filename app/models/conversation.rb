class Conversation < ApplicationRecord
  # Team visibility is in-app only; the public share link (share_token)
  # stays a separate, explicit owner action.
  enum :visibility, { personal: 0, team: 1 }, prefix: :visibility

  belongs_to :user
  belongs_to :team
  belongs_to :project, optional: true
  belongs_to :forked_from_message, class_name: "Message", optional: true
  # Present when a Routine fired this conversation (docs/routines.md).
  belongs_to :routine, optional: true
  has_many :messages, dependent: :destroy
  # Every distinct teammate who has sent a user message here. An
  # association, not a hand-rolled query, so list pages can preload it.
  has_many :senders, -> { merge(Message.user).distinct.order(:id) },
           through: :messages, source: :sender
  has_one :inflight_message, -> { inflight }, class_name: "Message"
  # nil for a normal chat; present once a workflow drives this conversation.
  has_one :workflow_run, dependent: :destroy

  # A conversation is owned by a team; default it to the creator's
  # personal team unless one was given (docs/tenancy.md).
  before_validation :default_team, on: :create

  # A destroyed conversation must not leave runtime state behind: cloud
  # runtimes leave a sandbox on the provider's servers (each kill hook
  # no-ops when its id is blank; idle reaping is EvictPausedSandboxesJob
  # for E2B, Daytona's native auto-delete interval for Daytona), and the
  # host runtimes leave a persistent scope directory, deleted after
  # commit by CleanupPersistentWorkspaceJob — never rm_rf inside the
  # destroy transaction. See docs/session-persistence.md.
  before_destroy :kill_paused_e2b_sandbox
  before_destroy :kill_daytona_sandbox
  after_destroy_commit :cleanup_persistent_workspace

  scope :recent, -> { order(updated_at: :desc) }
  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :starred, -> { where.not(starred_at: nil) }
  scope :shared, -> { where.not(share_token: nil) }
  # The three sidebar kinds, in the row's own identity precedence
  # (_convo.html.erb): a workflow run, else a routine fire, else a plain
  # chat. Used by the sidebar's kind filter.
  scope :chats, -> { where(routine_id: nil).where.missing(:workflow_run) }
  scope :workflows, -> { where.associated(:workflow_run) }
  scope :routines, -> { where.not(routine_id: nil) }
  scope :for_team, ->(team) { where(team: team) }
  # Coarse candidate scan for EvictDockerWorkspacesJob — Docker runtime,
  # quiet past the cutoff (messages touch the conversation, so updated_at
  # tracks turn activity). Precise eligibility (in-flight turn, active
  # workflow, workspace still on disk) is re-checked per row under the lock.
  scope :docker_workspace_evictable, ->(cutoff) {
    where("conversations.runtime_state->>'runtime' = ?", "docker")
      .where(updated_at: ..cutoff)
  }
  # The visibility rule, in one place: the launcher always, teammates
  # only when team-visible. Every surface (run page, gates, bridge
  # claims) must apply it through this scope or the predicate below.
  scope :accessible_to, ->(user) {
    where(visibility: :team).or(where(user_id: user.id))
  }
  # The conversation set a board view draws from: visible to the user,
  # narrowed by the board's scope (mine) and project filter. Shared by the
  # grid (Board) and the actor bar (BoardPresence) so they can't diverge.
  # Run-level facets (done window, needs_me) stay with each caller.
  scope :board_visible, ->(user, board_scope, project_ids) {
    rel = accessible_to(user)
    rel = rel.where(user_id: user.id) if board_scope == :mine
    rel = rel.where(project_id: project_ids) if project_ids.present?
    rel
  }
  # Everything a sidebar row asks per conversation — the run pill, the
  # running dot, participant avatars — batched for the whole page.
  scope :preloaded_for_sidebar, -> {
    includes(:workflow_run, :inflight_message,
             user: { avatar_attachment: :blob },
             senders: { avatar_attachment: :blob })
  }

  # Matching only — compose onto an already-authorized relation.
  def self.title_matching(query)
    normalized = query.to_s.strip
    where("conversations.title ILIKE ?", "%#{sanitize_sql_like(normalized)}%")
      .reorder(Arel.sql(sanitize_sql_array([ "similarity(conversations.title, ?) DESC", normalized ])))
      .order(updated_at: :desc, id: :desc)
  end

  def accessible_to?(user)
    user_id == user.id || visibility_team?
  end

  def archived?
    archived_at.present?
  end

  def starred?
    starred_at.present?
  end

  def shared?
    share_token.present?
  end

  # Mint a public share token on first call; later calls return the
  # existing token so the URL stays stable for already-distributed links.
  # shared_at records when it was first made public (the Sharing page
  # orders/labels by it — updated_at bumps on every message).
  def generate_share_token!
    return share_token if shared?
    update!(share_token: SecureRandom.urlsafe_base64(16), shared_at: Time.current)
    share_token
  end

  def revoke_share!
    update!(share_token: nil, shared_at: nil)
  end

  # Light up the "Team" tab for every teammate currently in this team —
  # they share the team's Turbo stream (see chat layout). Cleared when
  # their sidebar tab bar next re-renders.
  def broadcast_team_tab_dot!
    broadcast_replace_to(
      team,
      target: "team-tab-dot",
      partial: "conversations/team_tab_dot",
      locals: { active: true }
    )
  end

  # Soft-archive: hides the conversation from the active sidebar but
  # preserves all messages, attachments, and runtime state. Fully
  # reversible via #unarchive!. No-op if already archived.
  def archive!
    return if archived?
    update!(archived_at: Time.current)
  end

  def unarchive!
    return unless archived?
    update!(archived_at: nil)
  end

  # Star: surfaces the conversation under the sidebar's "Starred" filter
  # regardless of recency. Personal to the owner. No-op when unchanged.
  def star!
    return if starred?
    update!(starred_at: Time.current)
  end

  def unstar!
    return unless starred?
    update!(starred_at: nil)
  end

  # The owner first, then every other sender (composer or workflow gate).
  def participants
    @participants ||= [ user ] + (senders - [ user ])
  end

  # Only the owner has spoken — the chat skips sender attribution; with
  # one voice there is nobody to tell apart.
  def solo?
    participants.one?
  end

  TITLE_MAX = 60

  def display_title
    title.presence || "Untitled conversation"
  end

  # No-op once a title exists, so the caller (Message after_commit on user
  # rows) can fire on every user turn without worrying about double-writes.
  def generate_title_async!
    return if title.present?
    GenerateConversationTitleJob.perform_later(id)
  end

  # Persist a title chosen by the LLM (or fall back to a truncation of
  # the first user message). Called by the job, which already provided
  # the LLM call and sanitization; this method is the single place that
  # writes `title` and pushes the change to the UI.
  def apply_generated_title!(raw)
    cleaned = raw.to_s.strip.truncate(TITLE_MAX, omission: "").presence || fallback_title
    return if cleaned.blank?
    update!(title: cleaned)
    broadcast_title_change!
  end

  # A workflow conversation's first user message is the step prompt, not
  # the user's words — fall back to the run's input instead, or to
  # nothing, leaving the next turn free to retry the LLM title.
  def fallback_title
    source = workflow_run ? workflow_run.input
                          : messages.where(role: :user).order(:created_at).first&.content
    source.to_s.strip.truncate(TITLE_MAX, omission: "")
  end

  def broadcast_title_change!
    html = ERB::Util.html_escape(display_title)
    [ :sidebar_title, :title ].each do |key|
      Turbo::StreamsChannel.broadcast_update_to(
        self,
        target: ActionView::RecordIdentifier.dom_id(self, key),
        html: html
      )
    end
  end

  # The model in use, preferring the one pi actually resolved (captured
  # in agent_model after a turn) over the choice made at creation
  # (settings). nil before either is known.
  def model_label
    agent_model["name"].presence || settings["model"].presence
  end

  # The model / provider Metis passes pi for a turn: the conversation's
  # own choice, else the deployment default (config.x.agent). This is the
  # single source for both the `--model`/`--provider` flags (Adapters::Pi)
  # and the model line in AGENTS.md — the agent can't reliably name its
  # own model, so we hand it the real id.
  def configured_model
    settings["model"].presence || Rails.application.config.x.agent.model.presence
  end

  def configured_provider
    settings["provider"].presence || Rails.application.config.x.agent.provider.presence
  end

  # The runtime the last turn ran on (local, e2b), or nil before any.
  def runtime_label
    runtime_state["runtime"].presence
  end

  # True while a turn is running — an assistant message is still pending
  # or streaming. Used to refuse a second concurrent turn, so it stays a
  # live query unless inflight_message was preloaded for a list page.
  def turn_in_progress?
    return inflight_message.present? if association(:inflight_message).loaded?

    messages.inflight.exists?
  end

  # Stamp a cancellation request for the in-flight turn. ChatJob polls
  # this mid-stream (compared against the turn's start) and aborts pi.
  def request_cancel!
    update_column(:cancel_requested_at, Time.current)
  end

  # Every file uploaded across the conversation, as Active Storage
  # attachments. Runtimes project these into pi's workspace each turn —
  # they are durable input, not archived session state (see
  # docs/session-persistence.md).
  def uploaded_files
    messages.with_attached_files.flat_map { |message| message.files.attachments }
  end

  # Prior user/assistant turns, for replaying context into a fresh sandbox
  # whose predecessor (holding pi's transcript) was reaped — Agent::Identity
  # renders these. Excludes the in-flight turn: the current user message goes
  # to pi as the live prompt, and its pending assistant carries a higher id.
  def replayable_history
    current_user_id = messages.user.maximum(:id)
    scope = messages.conversational
    scope = scope.where("messages.id < ?", current_user_id) if current_user_id
    scope.chronological
  end

  def forked?
    forked_from_message_id.present?
  end

  def forked_from_conversation
    forked_from_message&.conversation
  end

  # A cloud-source fork replays its copied history into AGENTS.md; a host-backed
  # one (fork_pending) copies the real session instead, so it must not replay.
  def needs_history_replay?
    forked? && backend_session_id.blank? && !fork_pending?
  end

  private

  def default_team
    self.team ||= user&.personal_team
  end

  def kill_paused_e2b_sandbox
    Agent::Runtime::E2b.kill_sandbox(e2b_sandbox_id)
  end

  def kill_daytona_sandbox
    Agent::Runtime::Daytona.kill_sandbox(daytona_sandbox_id)
  end

  # Immutable scalars only — the row is gone by the time the job runs.
  def cleanup_persistent_workspace
    CleanupPersistentWorkspaceJob.perform_later(user_id: user_id, conversation_id: id)
  end
end
