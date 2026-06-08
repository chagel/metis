class WorkflowRunsController < ApplicationController
  before_action :set_run

  def approve
    @run.approve_current_gate!(by: current_user)
    respond_to_decision
  end

  def reject
    @run.reject_current_gate!(by: current_user)
    respond_to_decision
  end

  private

  # Scoped to the teams the user belongs to — a run in another team 404s.
  def set_run
    @run = WorkflowRun.where(team_id: current_user.teams.select(:id)).find(params[:id])
  end

  # The actor gets the regions back directly (reliable); the engine's
  # broadcaster pushes the same to any co-viewers and the owner's sidebar.
  def respond_to_decision
    WorkflowBroadcaster.new(@run).refresh
    respond_to do |format|
      format.turbo_stream { render "workflow_runs/update" }
      format.html { redirect_to @run.conversation }
    end
  end
end
