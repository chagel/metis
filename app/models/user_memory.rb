# What the agent has learned about a user within one team: recorded by the
# agent's memory tools, shown to every turn by Agent::Identity.
class UserMemory < ApplicationRecord
  MAX_CONTENT = 500
  MAX_PER_USER = 100
  SNAPSHOT = %w[content kind confidence source].freeze

  # Who's changing this memory, and why: set before a write so the change
  # lands in its MemoryChange history. A write without an actor isn't recorded.
  attr_accessor :change_actor, :change_conversation, :change_reason

  enum :kind, { preference: 0, correction: 1, fact: 2, goal: 3, commitment: 4, experience: 5 }
  enum :source, { stated: 0, inferred: 1 }, prefix: true
  enum :confidence, { low: 0, medium: 1, high: 2 }, prefix: true

  belongs_to :team
  belongs_to :user
  belongs_to :source_conversation, class_name: "Conversation", optional: true
  has_many :memory_changes, dependent: nil

  encrypts :content

  normalizes :content, with: ->(content) { content.to_s.strip }

  validates :content, presence: true, length: { maximum: MAX_CONTENT }
  validate :under_cap, on: :create

  after_create_commit :ensure_review
  after_create { record_change(:created) }
  after_update { record_change(:updated) if saved_changes.keys.intersect?(SNAPSHOT) }
  before_destroy { record_change(:forgotten) }

  scope :for, ->(user, team) { where(user: user, team: team) }
  scope :newest_first, -> { order(created_at: :desc) }
  scope :ordered, -> { order(:kind, confidence: :desc, created_at: :asc) }

  def self.available_in?(conversation)
    conversation.workflow_run.nil? && Membership.exists?(team_id: conversation.team_id, user_id: conversation.user_id)
  end

  def confirm!
    self.change_actor = :user
    update!(source: :stated, confidence: :high)
  end

  # The user's own wording: as good as stated, and a signal for the review.
  def edit_by_user(content)
    self.change_actor = :user
    self.content = content
    assign_attributes(source: :stated, confidence: :high, edited_by_user_at: Time.current) if content_changed?
    save
  end

  def snapshot = SNAPSHOT.index_with { public_send(it) }

  def snapshot_before_save = snapshot.merge(saved_changes.slice(*SNAPSHOT).transform_values(&:first))

  private

  def record_change(action)
    MemoryChange.record!(self, action) if change_actor
  end

  def under_cap
    return unless UserMemory.for(user, team).count >= MAX_PER_USER

    errors.add(:base, :cap_reached, count: MAX_PER_USER)
  end

  # The memory is already saved; a failed review setup must not report it lost.
  def ensure_review
    MemoryReview.ensure_for(user, team)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.error.report(e, handled: true)
  end
end
