class ProjectsController < ApplicationController
  # A top-level workspace surface, so it lives in the chat shell (sidebar
  # + primary nav) like the board — not the settings layout.
  layout "chat"

  before_action :set_project, only: %i[show edit update destroy]
  # Every rendering action sits in the chat shell, which needs the sidebar
  # data; destroy only redirects.
  before_action :set_sidebar, except: :destroy
  # Index + the read-only dashboard are team-visible; curating is admin.
  before_action :require_team_admin!, except: %i[index show]

  ACTIVITY_LIMIT = 50
  PANEL_LIMIT = 8

  def index
    @projects = team.projects.recent
  end

  def show
    mine = @project.conversations.merge(Conversation.accessible_to(current_user))
    @project_conversations = mine.recent.limit(PANEL_LIMIT)
    @runs = WorkflowRun.joins(:conversation)
                       .where(conversations: { project_id: @project.id })
                       .merge(Conversation.accessible_to(current_user))
                       .order(created_at: :desc).limit(PANEL_LIMIT)
    @activity = WebhookEvent.for_project(@project).recent.limit(ACTIVITY_LIMIT)
    @activity_total = WebhookEvent.for_project(@project).count
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
    params.require(:project).permit(:name, :about, :github_repo)
  end
end
