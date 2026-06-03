# Manage the active team (current_team) — members roster, rename,
# delete. Member-level role changes and invitations live in their own
# controllers.
class Settings::TeamsController < ApplicationController
  layout "settings"

  before_action :require_team_admin!, only: :update
  before_action :require_team_owner!, only: :destroy
  before_action :reject_personal_team!, only: %i[update destroy]

  def show
    @team = current_team
    if @team.personal?
      # The personal page is also where you find your way back to the
      # shared teams you belong to — list them so they're never lost.
      @joined_teams = current_user.memberships.joins(:team)
        .where(teams: { personal: false })
        .includes(team: :memberships).order("teams.name")
    else
      @memberships = @team.memberships.includes(user: { avatar_attachment: :blob })
      @invitation = Invitation.new
      @pending_invitations = @team.invitations.pending.order(:created_at)
    end
  end

  def update
    current_team.update!(team_params)
    redirect_to team_path, notice: "Team renamed."
  end

  def destroy
    name = current_team.name
    current_team.destroy
    session.delete(:current_team_id) # falls back to the personal team
    redirect_to team_path, notice: "#{name} deleted."
  end

  private

  def team_params
    params.require(:team).permit(:name)
  end
end
