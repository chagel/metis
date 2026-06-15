class Message < ApplicationRecord
  enum :role, { user: 0, assistant: 1, tool: 2, system: 3 }
  enum :streaming_status, { pending: 0, streaming: 1, done: 2, errored: 3, canceled: 4 }
  # Workflow timeline records render as markers, not chat bubbles:
  # step_prompt (engine-injected instruction), local_report (a delegated
  # step's outcome), review (a gate decision), handoff (a run Metis spun
  # off from this chat).
  enum :kind, { chat: 0, step_prompt: 1, local_report: 2, review: 3, handoff: 4 }

  belongs_to :conversation, touch: true
  # The human behind a user message (composer or gate reviewer); nil on
  # assistant rows, engine prompts, and rows predating the column.
  belongs_to :sender, class_name: "User", optional: true

  # Composer uploads. Images are sent to the agent inline (pi's vision
  # protocol); other files are staged into the agent's workspace so it
  # can open them with its file tools. See Agent::Adapters::Pi.
  has_many_attached :images
  has_many_attached :files

  # Files the agent published this turn — populated by ChatJob from the
  # runtime, never the user.
  has_many_attached :artifacts

  encrypts :content
  encrypts :reasoning

  ALLOWED_IMAGE_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze
  ALLOWED_FILE_TYPES = %w[
    application/pdf
    text/plain text/csv text/markdown
    application/json application/xml text/xml
  ].freeze
  ALLOWED_CONTENT_TYPES = (ALLOWED_IMAGE_TYPES + ALLOWED_FILE_TYPES).freeze
  MAX_UPLOAD_SIZE = 10.megabytes

  scope :chronological, -> { order(:created_at) }
  scope :conversational, -> { where(role: %i[user assistant]) }
  # An in-flight turn: the assistant message still pending or streaming.
  scope :inflight, -> { assistant.where(streaming_status: %i[pending streaming]) }

  # Once an assistant turn finishes, the conversation has enough context
  # (first user msg + first assistant reply) for a good title. Gating on
  # title.blank? makes this fire at most once and respects a user rename
  # that happened before this callback runs.
  after_commit :enqueue_title_generation, on: %i[create update]

  def attachments?
    images.attached? || files.attached?
  end

  def artifacts?
    artifacts.attached?
  end

  # End-to-end turn duration in seconds; nil until the turn finishes.
  def duration
    return unless started_at && finished_at

    finished_at - started_at
  end

  private

  def enqueue_title_generation
    return unless assistant? && done? && saved_change_to_streaming_status?
    conversation.generate_title_async!
  end
end
