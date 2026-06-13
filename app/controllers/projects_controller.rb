class ProjectsController < ApplicationController
  layout "settings"

  before_action :set_project, only: %i[edit update destroy]
  # Members use the team's projects (view); only admins curate them.
  before_action :require_team_admin!, except: :index

  def index
    @projects = team.projects.recent
  end

  def new
    @project = team.projects.new
  end

  def create
    @project = team.projects.new(project_params)
    @project.created_by = current_user
    @project.updated_by = current_user

    if @project.save
      redirect_to edit_project_path(@project), notice: t("flash.projects.create.notice")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    @project.assign_attributes(project_params)
    @project.updated_by = current_user

    if @project.save
      redirect_to edit_project_path(@project), notice: t("flash.projects.update.notice")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @project.name
    if @project.destroy
      redirect_to projects_path, notice: t("flash.projects.destroy.notice", name: name)
    else
      redirect_to edit_project_path(@project), alert: t("flash.projects.destroy.alert", name: name, error: @project.errors[:base].first)
    end
  end

  private

  def team
    current_team
  end

  def set_project
    @project = team.projects.find(params[:id])
  end

  def project_params
    params.require(:project).permit(:name, :about)
  end
end
