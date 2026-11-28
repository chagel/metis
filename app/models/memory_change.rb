# One change to a user's memory: what it was before and after, who made it
# (the nightly review, a chat, or the user) and why. Shown on the memory page
# so consolidation is never silent. Snapshots outlive a forgotten memory.
# Written by UserMemory's callbacks; see UserMemory#change_actor.
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
  scope :recent, -> { where(created_at: RETENTION.ago..).order(created_at: :desc, id: :desc) }

  def self.record!(memory, action)
    gone = action == :forgotten
    create!(
      team_id: memory.team_id, user_id: memory.user_id, user_memory: (memory unless gone), action: action,
      actor: memory.change_actor, conversation: memory.change_conversation, reason: memory.change_reason.to_s.strip.presence,
      before: { created: nil, updated: memory.snapshot_before_save, forgotten: memory.snapshot }[action],
      after: (memory.snapshot unless gone)
    )
  end

  def self.prune! = where(created_at: ...RETENTION.ago).delete_all
end
