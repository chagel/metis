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

  scope :for, ->(user, team) { where(user: user, team: team) }
  scope :ordered, -> { order(:kind, confidence: :desc, created_at: :asc) }

  def self.available_in?(conversation)
    conversation.workflow_run.nil? && conversation.team.members.include?(conversation.user)
  end

  def confirm!
    update!(source: :stated, confidence: :high)
  end

  private

  def under_cap
    return unless UserMemory.for(user, team).count >= MAX_PER_USER

    errors.add(:base, :cap_reached, count: MAX_PER_USER)
  end
end
