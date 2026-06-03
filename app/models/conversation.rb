class Conversation < ApplicationRecord
  belongs_to :user
  belongs_to :team
  belongs_to :project, optional: true
  has_many :messages, dependent: :destroy

  # A conversation is owned by a team; default it to the creator's
  # personal team unless one was given (docs/tenancy.md).
  before_validation :default_team, on: :create

  # E2B does not auto-clean paused sandboxes; if we forget to kill one
  # when its conversation is destroyed, it sits on E2B's servers
  # forever (see docs/coding-runtime.md). EvictPausedSandboxesJob is
  # the other side of this contract — for the long-idle case.
  before_destroy :kill_paused_e2b_sandbox

  scope :recent, -> { order(updated_at: :desc) }
  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :starred, -> { where.not(starred_at: nil) }
  scope :shared, -> { where.not(share_token: nil) }
  scope :for_team, ->(team) { where(team: team) }

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
  def generate_share_token!
    return share_token if shared?
    update!(share_token: SecureRandom.urlsafe_base64(16))
    share_token
  end

  def revoke_share!
    update!(share_token: nil)
  end

  # Light up the "Shared" tab for every teammate currently in this team —
  # they share the team's Turbo stream (see chat layout). Cleared when
  # their sidebar tab bar next re-renders.
  def broadcast_shared_to_team!
    broadcast_replace_to(
      team,
      target: "shared-tab-dot",
      partial: "conversations/shared_tab_dot",
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

  TITLE_MAX = 60

  def display_title
    title.presence || "Untitled conversation"
  end

  # No-op once a title exists, so the caller (Message after_commit) can
  # fire on every assistant turn without worrying about double-writes.
  def generate_title_async!
    return if title.present?
    GenerateConversationTitleJob.perform_later(id)
  end

  # Persist a title chosen by the LLM (or fall back to a truncation of
  # the first user message). Called by the job, which already provided
  # the LLM call and sanitization; this method is the single place that
  # writes `title` and pushes the change to the UI.
  def apply_generated_title!(raw)
    cleaned = raw.to_s.strip.truncate(TITLE_MAX, omission: "").presence ||
              messages.where(role: :user).order(:created_at).first&.content.to_s
                       .strip.truncate(TITLE_MAX, omission: "")
    return if cleaned.blank?
    update!(title: cleaned)
    broadcast_title_change!
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
  # or streaming. Used to refuse a second concurrent turn.
  def turn_in_progress?
    messages.where(role: :assistant, streaming_status: %i[pending streaming]).exists?
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

  private

  def default_team
    self.team ||= user&.personal_team
  end

  def kill_paused_e2b_sandbox
    Agent::Runtime::E2b.kill_sandbox(e2b_sandbox_id)
  end
end
