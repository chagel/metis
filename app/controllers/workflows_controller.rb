# Authoring for workflow templates (catalog + editor). Runs launch via
# WorkflowRunsController.
class WorkflowsController < ApplicationController
  layout "settings"

  before_action :set_workflow, only: %i[edit update destroy]
  before_action :require_team_admin!, except: :index

  def index
    @workflows = current_team.workflows.order(:name)
  end

  def new
    @workflow = current_team.workflows.new
  end

  def create
    @workflow = current_team.workflows.new(workflow_params)
    if @workflow.save
      redirect_to edit_workflow_path(@workflow), notice: t("flash.workflows.create.notice")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @workflow.update(workflow_params)
      redirect_to edit_workflow_path(@workflow), notice: t("flash.workflows.update.notice")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @workflow.name
    @workflow.destroy
    redirect_to workflows_path, notice: t("flash.workflows.destroy.notice", name: name)
  end

  private

  def set_workflow
    @workflow = current_team.workflows.find(params[:id])
  end

  def workflow_params
    permitted = params.require(:workflow).permit(:name, :description, :default_project_id, :trigger_source)
    permitted[:default_project_id] = nil if permitted[:default_project_id].blank?
    permitted[:steps] = Workflow.normalize_steps(params.dig(:workflow, :steps))
    permitted
  end
end
