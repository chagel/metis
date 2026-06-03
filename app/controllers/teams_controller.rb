class TeamsController < ApplicationController
  layout "settings"

  def new
    @team = Team.new
  end

  # Create a named shared team, make the creator its owner, and switch
  # into it. Personal teams are never created here — they're minted at
  # signup (docs/tenancy.md).
  def create
    @team = Team.new(team_params.merge(personal: false))
    ActiveRecord::Base.transaction do
      @team.save!
      current_user.memberships.create!(team: @team, role: :owner)
    end
    session[:current_team_id] = @team.id
    redirect_to team_path, notice: "#{@team.name} created."
  rescue ActiveRecord::RecordInvalid
    render :new, status: :unprocessable_entity
  end

  # Set the active team for subsequent requests. Scoped to the user's
  # own teams, so a non-member id 404s rather than switching
  # (docs/tenancy.md).
  def switch
    team = current_user.teams.find(params[:id])
    session[:current_team_id] = team.id
    # The sidebar switcher returns to chat; the settings team list keeps
    # you in settings on the now-active team.
    redirect_to params[:to] == "settings" ? team_path : root_path
  end

  private

  def team_params
    params.require(:team).permit(:name)
  end
end
