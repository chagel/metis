module SharingHelper
  # What the viewer has shared publicly in this team: chats plus artifacts.
  def shared_items_count
    @shared_items_count ||= current_user.conversations.where(team: current_team).shared.count +
      ArtifactShare.minted_by(current_user).where(team: current_team).count
  end
end
