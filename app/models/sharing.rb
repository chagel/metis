# The Sharing page's read model: everything a team currently shares
# publicly — conversations and artifacts — grouped for display. Pure
# projection, never writes state (see Board).
class Sharing
  def self.for(team:)
    new(team: team)
  end

  def initialize(team:)
    @team = team
  end

  def conversations
    @conversations ||= @team.conversations.shared.recent.to_a
  end

  def artifact_shares
    @artifact_shares ||= ArtifactShare.where(team: @team)
                                      .includes(:blob).order(created_at: :desc).to_a
  end

  def any?
    conversations.any? || artifact_shares.any?
  end
end
