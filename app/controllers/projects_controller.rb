class ProjectsController < ApplicationController
  # A top-level workspace surface, so it lives in the chat shell (sidebar
  # + primary nav) like the board — not the settings layout.
  layout "chat"

  before_action :set_project, only: %i[show edit update destroy]
  # Every rendering action sits in the chat shell, which needs the sidebar
  # data; destroy redirects and linear_projects answers JSON.
  before_action :set_sidebar, except: %i[destroy linear_projects]
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
    # Only an actual infinite-scroll page (?page=) gets the turbo_stream. The
    # post-create redirect follows with a turbo-stream Accept header it
    # inherited from the form POST; without this it would render the
    # pagination stream (a no-op on that page) instead of navigating here.
    return render(:show, formats: :turbo_stream) if params[:page].present?

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
    render :show, formats: :html
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

  # The team's Linear projects, fetched live with the member's connector
  # bearer for the form picker. A missing connection or a Linear blip
  # answers with an error the form degrades on, never a 500.
  def linear_projects
    render json: { projects: fetch_linear_projects }
  rescue StandardError => error
    Rails.logger.warn("linear_projects failed — #{error.class}: #{error.message}")
    render json: { error: error.message }, status: :bad_gateway
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

  # The operator binds a project by name; the picker resolves it to the
  # Linear project UUID stored in external_refs. Read-only, the member's
  # own connector grant — no extra scope beyond what Linear already gave us.
  def fetch_linear_projects
    connector = team.connectors.find_by(catalog_key: "linear")
    bearer = connector&.credential_for(current_user)&.linear_api_bearer
    raise Linear::Api::Error, "Authorize Linear API access on the connector page first." if bearer.blank?

    Linear::Api.new(bearer).projects
  end

  def project_params
    params.require(:project).permit(:name, :about, :github_repo, :linear_project)
  end
end
