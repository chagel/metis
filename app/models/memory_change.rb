# One change to a user's memory: what it was before and after, who made it
# (the nightly review, a chat, or the user) and why. Shown on the memory page
# so consolidation is never silent. Snapshots outlive a forgotten memory.
class MemoryChange < ApplicationRecord
  RETENTION = 90.days

  enum :action, { created: 0, updated: 1, forgotten: 2 }
  enum :actor, { review: 0, chat: 1, user: 2 }, prefix: :by

  belongs_to :team
  belongs_to :user
  belongs_to :user_memory, optional: true
  belongs_to :conversation, optional: true

  serialize :before, coder: JSON
  serialize :after, coder: JSON
  encrypts :before, :after, :reason

  scope :for, ->(user, team) { where(user: user, team: team) }
  scope :recent, -> { where(created_at: 30.days.ago..).order(created_at: :desc, id: :desc) }

  def self.record!(memory, action:, actor:, before: nil, conversation: nil, reason: nil)
    create!(
      team_id: memory.team_id, user_id: memory.user_id, user_memory: (memory unless action.to_s == "forgotten"),
      action: action, actor: actor, conversation: conversation, reason: reason.to_s.strip.presence,
      before: before, after: (memory.snapshot unless action.to_s == "forgotten")
    )
  end

  def self.prune! = where(created_at: ...RETENTION.ago).delete_all
end
