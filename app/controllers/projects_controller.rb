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

  ACTIVITY_PAGE_SIZE = 30
  PANEL_LIMIT = 8

  # The sidebar is the list; land on a project (last opened, else most
  # recent), not a duplicate of it. No projects → the empty-state prompt.
  def index
    @projects = team.projects.recent
    target = last_visited_project || @projects.first
    redirect_to project_path(target) and return if target
  end

  def show
    remember_visit(@project)
    @activity_pagy, @activity = pagy(:countless, WebhookEvent.for_project(@project).recent,
                                     limit: ACTIVITY_PAGE_SIZE)
    # Infinite-scroll fetches (show.turbo_stream) need only the next page.
    return if params[:page].present?

    visible = Conversation.accessible_to(current_user)
    runs = WorkflowRun.joins(:conversation)
                      .where(conversations: { project_id: @project.id }).merge(visible)
    @runs_total = runs.count
    # Only runs needing a human (a gate, a local claim, a queued start) are
    # worth surfacing.
    @awaiting_runs = runs.merge(WorkflowRun.awaiting)
                         .includes(:conversation).order(updated_at: :desc).limit(PANEL_LIMIT)
    @conversations_total = @project.conversations.merge(visible).count
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

  # Last project opened, so clicking Projects returns where you were.
  # Scoped to the team's own projects, so a stale id from another team (or
  # a deleted project) just resolves to nil and index falls back.
  def last_visited_project
    team.projects.find_by(id: session[:last_project_id])
  end

  def remember_visit(project)
    session[:last_project_id] = project.id
  end

  def project_params
    params.require(:project).permit(:name, :about, :github_repo)
  end
end
