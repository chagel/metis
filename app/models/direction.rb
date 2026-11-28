# Something a user asked Metis to follow ("keep me current on proactive
# agents"). The nightly foresight run explores it, keeps its view and open
# questions current, and records hunches from it. See docs/hunches.md.
class Direction < ApplicationRecord
  MAX_PER_USER = 10

  enum :status, { active: 0, paused: 1 }

  belongs_to :team
  belongs_to :user
  has_many :hunches, dependent: :nullify

  encrypts :brief, :view

  normalizes :title, with: ->(title) { title.to_s.strip }

  validates :title, presence: true, length: { maximum: 120 }
  validate :under_cap, on: :create

  after_create_commit :ensure_foresight

  scope :for, ->(user, team) { where(user: user, team: team) }

  private

  def under_cap
    return unless Direction.for(user, team).count >= MAX_PER_USER

    errors.add(:base, :cap_reached, count: MAX_PER_USER)
  end

  def ensure_foresight
    Foresight.ensure_for(user, team)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.error.report(e, handled: true)
  end
end
