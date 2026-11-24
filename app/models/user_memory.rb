# What the agent has learned about a user within one team: recorded by the
# agent's memory tools, shown to every turn by Agent::Identity.
class UserMemory < ApplicationRecord
  MAX_CONTENT = 500
  MAX_PER_USER = 100

  enum :kind, { preference: 0, correction: 1, fact: 2, goal: 3, commitment: 4, experience: 5 }
  enum :source, { stated: 0, inferred: 1 }, prefix: true
  enum :confidence, { low: 0, medium: 1, high: 2 }, prefix: true

  belongs_to :team
  belongs_to :user
  belongs_to :source_conversation, class_name: "Conversation", optional: true

  encrypts :content

  normalizes :content, with: ->(content) { content.to_s.strip }

  validates :content, presence: true, length: { maximum: MAX_CONTENT }
  validate :under_cap, on: :create

  after_create_commit { MemoryReview.ensure_for(user, team) }

  scope :for, ->(user, team) { where(user: user, team: team) }
  scope :newest_first, -> { order(created_at: :desc) }
  scope :ordered, -> { order(:kind, confidence: :desc, created_at: :asc) }

  def self.available_in?(conversation)
    conversation.workflow_run.nil? && Membership.exists?(team_id: conversation.team_id, user_id: conversation.user_id)
  end

  def confirm!
    update!(source: :stated, confidence: :high)
  end

  # The user's own wording: as good as stated, and a signal for the review.
  def edit_by_user(content)
    self.content = content
    assign_attributes(source: :stated, confidence: :high, edited_by_user_at: Time.current) if content_changed?
    save
  end

  private

  def under_cap
    return unless UserMemory.for(user, team).count >= MAX_PER_USER

    errors.add(:base, :cap_reached, count: MAX_PER_USER)
  end
end
