class WorkflowRunsController < ApplicationController
  include Composing

  before_action :set_run, only: %i[approve reject request_changes start]
  before_action :set_workflow, only: :create

  def create
    # A run needs a project: daemons claim local steps per project, so a
    # project-less run could never be auto-claimed.
    project = current_team.projects.find_by(id: params[:project_id]) || @workflow.default_project
    if project.nil?
      return render_composer_error(nil, t("flash.composer.pick_project"))
    end
    run = WorkflowRun.start(
      team: current_team, user: current_user, workflow: @workflow,
      project: project, input: params[:input].presence || params[:content],
      settings: chat_settings, visibility: composed_visibility,
      title: @workflow.run_title
    )
    redirect_to run.conversation
  end

  # Start a queued run (chat handoffs queue rather than start immediately).
  def start
    @run.launch!
    redirect_to @run.conversation
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

  # Manual claim from the run timeline (auto-claim off). Delegates to
  # the id-scoped atomic claim so it grabs this step, not FIFO.
  def claim
    run = find_run(:workflow_run_id)
    return head :not_found unless run.conversation.accessible_to?(current_user)

    task = Task.claim_next_for(current_user, client: "metis-web", id: params[:id])
    if task
      step_name = task.display_name
      step_name = t("task.default_name") if step_name == "the step"
      redirect_to run.conversation, notice: t("flash.workflow_runs.claim.claimed", step: step_name)
    else
      redirect_to run.conversation, alert: t("flash.workflow_runs.claim.unavailable")
    end
  end

  private

  # Gate actions follow visibility: the launcher always, teammates only on
  # team-visible runs — a personal run's gates are not the team's to act on.
  def set_run
    @run = find_run(:id)
    head :not_found unless @run.conversation.accessible_to?(current_user)
  end

  def find_run(param_key = :id)
    WorkflowRun.where(team: current_user.teams).find(params[param_key])
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
