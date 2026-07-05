# The Sharing page's read model: everything a team currently shares
# publicly — conversations and artifacts — grouped for display. Pure
# projection, never writes state.
class Sharing
  def self.for(team:, user:)
    new(team: team, user: user)
  end

  def initialize(team:, user:)
    @team = team
    @user = user
  end

  # Only conversations the viewer may actually open in-app: a teammate
  # must never see the title/public URL of another member's personal
  # conversation just because it was shared publicly.
  def conversations
    @conversations ||= @team.conversations.shared
                            .merge(Conversation.accessible_to(@user))
                            .order(shared_at: :desc).to_a
  end

  def artifact_shares
    @artifact_shares ||= ArtifactShare.where(team: @team).accessible_to(@user)
                                      .includes(:blob).order(created_at: :desc).to_a
  end

  def any?
    conversations.any? || artifact_shares.any?
  end
end
