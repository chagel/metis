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

  # The sidebar is the project list (master); the pane shows a project
  # (detail), so land on the last one opened (or the most recent), never a
  # duplicate of the list. No projects → the empty state prompts the first.
  def index
    @projects = team.projects.recent
    target = last_visited_project || @projects.first
    redirect_to project_path(target) and return if target
  end

  def show
    remember_visit(@project)
    conversations = @project.conversations.merge(Conversation.accessible_to(current_user))
    @project_conversations = conversations.recent.limit(PANEL_LIMIT)
    @conversations_total = conversations.count

    runs = WorkflowRun.joins(:conversation)
                      .where(conversations: { project_id: @project.id })
                      .merge(Conversation.accessible_to(current_user))
    @runs = runs.order(created_at: :desc).limit(PANEL_LIMIT)
    @runs_total = runs.count

    activity = WebhookEvent.for_project(@project)
    @activity = activity.recent.limit(ACTIVITY_LIMIT)
    @activity_total = activity.count
  end

  def new
    @project = team.projects.new
  end

  def create
    @project = team.projects.new(project_params)
    @project.created_by = current_user
    @project.updated_by = current_user

    if @project.save
      redirect_to project_path(@project), notice: t("flash.projects.create.notice")
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

  # Last project opened, kept per team in the session (like current_team_id)
  # so clicking Projects returns where you were. nil when none recorded, the
  # record is gone, or it belongs to another team — index then falls back.
  def last_visited_project
    id = (session[:last_project] || {})[current_team.id.to_s]
    team.projects.find_by(id: id) if id
  end

  def remember_visit(project)
    session[:last_project] = (session[:last_project] || {}).merge(current_team.id.to_s => project.id)
  end

  def project_params
    params.require(:project).permit(:name, :about, :github_repo)
  end
end
