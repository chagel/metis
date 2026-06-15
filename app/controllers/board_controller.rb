# The cross-project run board (docs/workflows.md). Read-only: a projection
# of every visible WorkflowRun into status columns and project swimlanes.
class BoardController < ApplicationController
  layout "chat"

  before_action :set_filters
  before_action :set_sidebar, only: :index

  def index
    @board = Board.for(team: current_team, user: current_user,
                       scope: @scope, project_ids: @project_ids, window: Board::DONE_WINDOWS[@done])
    @presence = board_presence
  end

  # The actors bar/panel only — polled (~20s) so coarse machine presence
  # ages from online to stale without a page reload. Carries the active
  # filters so the polled bar stays in sync with the filtered grid.
  def actors
    render turbo_stream: turbo_stream.replace(
      "board_actors", partial: "board/actors",
      locals: { presence: board_presence,
                poll_query: helpers.board_filter_query(scope: @scope, done: @done, projects: @project_ids) }
    )
  end

  private

  def set_filters
    @scope = board_scope
    @done = board_done
    @projects = current_team.projects.order(:name).to_a
    @project_ids = selected_project_ids
  end

  def board_presence
    BoardPresence.for(team: current_team, user: current_user,
                      scope: @scope, project_ids: @project_ids)
  end

  def board_scope
    Board::SCOPES.find { |scope| scope.to_s == params[:scope] } || :all
  end

  def board_done
    Board::DONE_WINDOWS.key?(params[:done]) ? params[:done] : "24h"
  end

  # The chosen project ids, intersected with the team's own projects so a
  # stale or forged id can't widen the filter.
  def selected_project_ids
    Array(params[:projects]).map(&:to_i) & @projects.map(&:id)
  end
end
