class SharingController < ApplicationController
  layout "chat"

  before_action :set_sidebar

  def index
    # A personal workspace is a team of one — no team scope to show.
    @scope = params[:scope] == "team" && !current_team.personal? ? :team : :mine
    @kind = %w[chats artifacts].include?(params[:kind]) ? params[:kind].to_sym : :all
    @sharing = Sharing.for(team: current_team, user: current_user, scope: @scope, kind: @kind)
  end
end
