# The cross-project run board (docs/workflows.md). Read-only: a projection
# of every visible WorkflowRun into status columns and project swimlanes.
class BoardController < ApplicationController
  layout "chat"

  before_action :set_sidebar

  def index
    @board = Board.for(team: current_team, user: current_user)
  end
end
