class SharingController < ApplicationController
  layout "chat"

  before_action :set_sidebar

  def index
    @sharing = Sharing.for(team: current_team, user: current_user)
  end
end
