# The Sharing page's read model: a team's public shares, scoped like the
# chats sidebar — :mine is what the viewer created (every card revocable),
# :team is what teammates expose from conversations the viewer may open —
# and narrowed by kind (:all / :chats / :artifacts). Pure
# projection, never writes state.
class Sharing
  def self.for(team:, user:, scope: :mine, kind: :all)
    new(team: team, user: user, scope: scope, kind: kind)
  end

  def initialize(team:, user:, scope: :mine, kind: :all)
    @team = team
    @user = user
    @scope = scope.to_sym
    @kind = kind.to_sym
  end

  # One stream, newest first — conversations and artifacts interleaved
  # in the order they were shared.
  def items
    @items ||= begin
      list = []
      list += conversations unless @kind == :artifacts
      list += artifact_shares unless @kind == :chats
      list.sort_by { |item| shared_at(item) }.reverse
    end
  end

  def shared_at(item)
    item.is_a?(ArtifactShare) ? item.created_at : (item.shared_at || item.updated_at)
  end

  def any?
    items.any?
  end

  # The :team scope keeps the visibility rule: a teammate must never see
  # the title/public URL of another member's personal conversation just
  # because it was shared publicly.
  def conversations
    @conversations ||= begin
      rel = @team.conversations.shared
      rel = if team_scope?
        rel.merge(Conversation.accessible_to(@user)).where.not(user_id: @user.id)
      else
        rel.where(user_id: @user.id)
      end
      rel.to_a
    end
  end

  def artifact_shares
    @artifact_shares ||= begin
      rel = ArtifactShare.where(team: @team)
      rel = if team_scope?
        rel.accessible_to(@user).where.not(created_by_id: @user.id)
      else
        rel.minted_by(@user)
      end
      rel.includes(:blob).to_a
    end
  end

  private

  def team_scope? = @scope == :team
end
