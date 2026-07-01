# A team — the single tenancy unit (docs/tenancy.md). Every ownable
# resource belongs to a team. A personal account is a team of one,
# created for each user at signup.
class Team < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :members, through: :memberships, source: :user
  has_many :conversations, dependent: :destroy
  has_many :connectors, dependent: :destroy
  has_many :skills, dependent: :destroy
  has_many :projects, dependent: :destroy
  has_many :workflows, dependent: :destroy
  has_many :workflow_runs, dependent: :destroy
  has_many :routines, dependent: :destroy
  has_many :webhook_events, dependent: :destroy
  has_many :invitations, dependent: :destroy

  validates :name, presence: true

  # A personal team-of-one shows as "Personal" rather than its raw name
  # (which is the owner's email).
  def display_name
    personal? ? "Personal" : name
  end

  # Admins and owners curate the team's shared tools; plain members use them.
  # The one rule the UI (require_team_admin!) and the agent tools share.
  def managed_by?(user)
    memberships.find_by(user: user)&.manages_team? || false
  end

  # Hand ownership to another member and step the current owner down to
  # admin, atomically — preserving the single-owner invariant.
  def transfer_ownership!(from:, to:)
    transaction do
      from.update!(role: :admin)
      to.update!(role: :owner)
    end
  end
end
