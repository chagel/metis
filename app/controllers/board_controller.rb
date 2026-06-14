# The cross-project run board (docs/workflows.md). Read-only: a projection
# of every visible WorkflowRun into status columns and project swimlanes.
class BoardController < ApplicationController
  layout "chat"

  before_action :set_sidebar, only: :index

  def index
    @scope = board_scope
    @done = board_done
    @project_id = params[:project].presence
    @project = current_team.projects.find_by(id: @project_id) if @project_id
    @board = Board.for(team: current_team, user: current_user,
                       scope: @scope, project_id: @project_id, window: Board::DONE_WINDOWS[@done])
    @presence = BoardPresence.for(team: current_team, user: current_user)
  end

  # The actors bar/panel only — polled (~20s) so coarse machine presence
  # ages from online to stale without a page reload.
  def actors
    @presence = BoardPresence.for(team: current_team, user: current_user)
    render turbo_stream: turbo_stream.replace(
      "board_actors", partial: "board/actors", locals: { presence: @presence }
    )
  end

  private

  def board_scope
    Board::SCOPES.find { |scope| scope.to_s == params[:scope] } || :all
  end

  def board_done
    Board::DONE_WINDOWS.key?(params[:done]) ? params[:done] : "24h"
  end
end
