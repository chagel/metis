# Joins a user to a team with a role — the authorization primitive
# (docs/tenancy.md). A user may touch a resource when
# `resource.team.members.include?(user)`.
class Membership < ApplicationRecord
  # Roles assignable through member management. Owner is excluded — it
  # moves only via ownership transfer, keeping exactly one owner.
  ASSIGNABLE_ROLES = %w[member admin].freeze

  belongs_to :user
  belongs_to :team

  enum :role, { member: 0, admin: 1, owner: 2 }

  validates :role, presence: true
  validates :user_id, uniqueness: { scope: :team_id }

  # A departing member's public artifact links die with the membership —
  # revocation is creator-only, so nobody left in the team could revoke them.
  after_destroy { ArtifactShare.minted_by(user).where(team: team).delete_all }
  after_destroy { UserMemory.for(user, team).delete_all }

  # Owners and admins manage the team (members, settings); plain
  # members only use its shared resources.
  def manages_team?
    admin? || owner?
  end

  # Memories the user deleted on the memory page, as { kind, at } with no
  # text, kept 30 days so the nightly review knows what was rejected.
  def record_memory_deletions!(kinds)
    kept = memory_deletions.select { |deletion| Time.iso8601(deletion["at"]) > 30.days.ago }
    update!(memory_deletions: kept + kinds.map { |kind| { "kind" => kind, "at" => Time.current.iso8601 } })
  end

  def memory_deletions_since(time)
    memory_deletions.select { |deletion| Time.iso8601(deletion["at"]) >= time }.map { |deletion| deletion["kind"] }.tally
  end
end
