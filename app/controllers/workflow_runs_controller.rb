class WorkflowRunsController < ApplicationController
  include Composing

  before_action :set_run, only: %i[approve reject request_changes]
  before_action :set_workflow, only: :create

  def create
    project = current_team.projects.find_by(id: params[:project_id]) || @workflow.default_project
    run = WorkflowRun.start(
      team: current_team, user: current_user, workflow: @workflow,
      project: project, input: params[:input].presence || params[:content],
      settings: chat_settings
    )
    redirect_to run.conversation
  end

  def approve
    @run.approve_current_gate!(by: current_user)
    respond_to_decision
  end

  def reject
    @run.reject_current_gate!(by: current_user)
    respond_to_decision
  end

  def request_changes
    @run.request_changes!(params[:feedback], by: current_user)
    respond_to_decision
  end

  private

  # Scoped to the teams the user belongs to — a run in another team 404s.
  def set_run
    @run = WorkflowRun.where(team_id: current_user.teams.select(:id)).find(params[:id])
  end

  def set_workflow
    @workflow = current_team.workflows.find(params[:workflow_id])
  end

  # Actor gets the regions back directly; the broadcaster pushes them to
  # co-viewers and the owner's sidebar. Reload first — the enqueued advance
  # job may already have moved the run, and a stale render would overwrite
  # its fresher broadcast.
  def respond_to_decision
    @run.reload
    WorkflowBroadcaster.new(@run).refresh
    respond_to do |format|
      format.turbo_stream { render "workflow_runs/update" }
      format.html { redirect_to @run.conversation }
    end
  end
end
