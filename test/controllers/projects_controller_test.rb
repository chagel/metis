require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "proj-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in @user
  end

  def team = @user.personal_team

  test "index renders the empty-state copy when the team has no projects" do
    get projects_path
    assert_response :success
    assert_select ".pane-empty", text: /No projects yet/
  end

  test "index lands on the most recent project rather than duplicating the sidebar list" do
    team.projects.create!(name: "Older")
    newest = team.projects.create!(name: "Newest")

    get projects_path
    assert_redirected_to project_path(newest)
  end

  test "index returns to the last visited project, not the most recent" do
    older = team.projects.create!(name: "Older")
    team.projects.create!(name: "Newest")

    get project_path(older)   # records the visit
    get projects_path
    assert_redirected_to project_path(older)
  end

  test "index falls back to the most recent when the remembered project is gone" do
    older = team.projects.create!(name: "Older")
    newest = team.projects.create!(name: "Newest")

    get project_path(older)
    older.destroy
    get projects_path
    assert_redirected_to project_path(newest)
  end

  test "create persists name + about and stamps created_by / updated_by" do
    assert_difference -> { team.projects.count }, 1 do
      post projects_path, params: { project: { name: "Metis", about: "Rails 8.1 chat over pi." } }
    end
    project = team.projects.find_by!(name: "Metis")
    assert_equal "Rails 8.1 chat over pi.", project.about
    assert_equal @user.id, project.created_by_id
    assert_equal @user.id, project.updated_by_id
    assert_redirected_to project_path(project)
  end

  test "create with a blank name re-renders the new form" do
    post projects_path, params: { project: { name: "" } }
    assert_response :unprocessable_entity
    assert_select ".flash.error"
  end

  test "update edits name and about" do
    project = team.projects.create!(name: "Metis")
    patch project_path(project), params: { project: { name: "Metis 2", about: "edited" } }
    project.reload
    assert_equal "Metis 2", project.name
    assert_equal "edited", project.about
    assert_redirected_to edit_project_path(project)
  end

  test "destroy deletes the project and detaches (does not destroy) its conversations" do
    project = team.projects.create!(name: "Metis")
    conversation = @user.conversations.create!(project: project)

    assert_difference -> { team.projects.count }, -1 do
      assert_no_difference -> { @user.conversations.count } do
        delete project_path(project)
      end
    end
    assert_nil conversation.reload.project_id
    assert_redirected_to projects_path
  end

  test "another team's project is not accessible" do
    other = Team.create!(name: "Other")
    foreign = other.projects.create!(name: "Secret")
    get edit_project_path(foreign)
    assert_response :not_found
  end

  # A team where @user is a plain member, switched in as the current team.
  def shared_team_as_member
    owner = User.create!(email: "po-#{SecureRandom.hex(4)}@example.com", password: "password123")
    team = Team.create!(name: "Shared")
    team.memberships.create!(user: owner, role: :owner)
    team.memberships.create!(user: @user, role: :member)
    post switch_team_path(team)
    team
  end

  test "the dashboard is team-visible (a non-admin member can open it)" do
    project = shared_team_as_member.projects.create!(name: "Metis")
    get project_path(project)
    assert_response :success
    assert_select ".pane-title", text: "Metis"
  end

  test "the dashboard shows the empty activity state for a project with no events" do
    project = team.projects.create!(name: "Metis")
    get project_path(project)
    assert_response :success
    assert_select "p", text: /No GitHub activity yet/
  end

  test "the dashboard surfaces only runs awaiting a human under Needs you" do
    project = team.projects.create!(name: "Metis")
    gated = @user.conversations.create!(project: project, title: "Gated run")
    team.workflow_runs.create!(conversation: gated, status: :awaiting_approval)
    done = @user.conversations.create!(project: project, title: "Done run")
    team.workflow_runs.create!(conversation: done, status: :completed)

    get project_path(project)
    assert_response :success
    assert_select ".panel--attn .panel-title", text: "Needs you"
    assert_select ".panel--attn .panel-link", text: "Gated run"
    assert_select ".panel--attn .run-chip", text: "Needs approval"
    # The completed run isn't actionable — it stays out of the attention panel.
    assert_select ".panel--attn .panel-link", text: "Done run", count: 0
  end

  test "the dashboard hides Needs you when no run awaits a human" do
    project = team.projects.create!(name: "Metis")
    conv = @user.conversations.create!(project: project)
    team.workflow_runs.create!(conversation: conv, status: :completed)

    get project_path(project)
    assert_response :success
    assert_select ".panel--attn", count: 0
  end

  def make_events(project, count)
    count.times do |i|
      WebhookEvent.create!(team: team, project: project, provider: :github,
                           event_type: "push", external_id: "ev-#{i}",
                           payload: { "ref" => "refs/heads/main", "commits" => [ {} ],
                                      "sender" => { "login" => "octo" } })
    end
  end

  test "the activity feed paginates: first page shows a sentinel when more remain" do
    project = team.projects.create!(name: "Metis")
    make_events(project, ProjectsController::ACTIVITY_PAGE_SIZE + 5)

    get project_path(project)
    assert_response :success
    assert_select ".activity-list[data-controller='infinite-scroll']"
    assert_select "#activity-sentinel[data-url*='page=2']"
    assert_select ".activity-item", count: ProjectsController::ACTIVITY_PAGE_SIZE
  end

  test "no sentinel when a single page covers every event" do
    project = team.projects.create!(name: "Metis")
    make_events(project, 3)

    get project_path(project)
    assert_select "#activity-sentinel", count: 0
  end

  test "requesting a page returns a turbo_stream that appends the next rows" do
    project = team.projects.create!(name: "Metis")
    make_events(project, ProjectsController::ACTIVITY_PAGE_SIZE + 5)

    get project_path(project, page: 2), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match %r{turbo-stream action="before" target="activity-sentinel"}, response.body
    # Last page → the sentinel is removed, not replaced.
    assert_match %r{turbo-stream action="remove" target="activity-sentinel"}, response.body
  end

  test "the dashboard renders the project's webhook events as activity lines" do
    project = team.projects.create!(name: "Metis", github_repo: "chagel/metis")
    WebhookEvent.create!(team: team, project: project, provider: :github,
                         event_type: "pull_request.opened", external_id: "d-1",
                         payload: { "number" => 9, "pull_request" => { "title" => "Ship it", "html_url" => "https://gh/pr/9" },
                                    "sender" => { "login" => "octo" } })
    get project_path(project)
    assert_response :success
    assert_select ".activity-actor", text: "octo"
    assert_select "a.activity-summary", text: "opened PR #9: Ship it"
  end

  test "the sidebar primary nav carries a Projects tab" do
    get projects_path
    assert_response :success
    assert_select ".prnav a.prnav-item.on", text: "Projects"
  end

  test "projects shows the project list in the sidebar, not conversations, and stays expanded" do
    project = team.projects.create!(name: "Metis")
    get project_path(project)
    assert_response :success
    assert_select ".app.sidebar-collapsed", count: 0
    assert_select ".prjnav .prjnav-item.on", text: /Metis/
    assert_select ".sidebar .search", count: 0
    assert_select ".sidebar-rail a.rail-dest", minimum: 4
  end

  test "a sidebar project card shows name, repo, and only its non-zero stats" do
    project = team.projects.create!(name: "web", github_repo: "pipihosting/pipi-web")
    @user.conversations.create!(project: project)
    WebhookEvent.create!(team: team, project: project, provider: :github,
                         event_type: "push", external_id: "e1", payload: {})
    get project_path(project)
    assert_response :success
    assert_select ".prjnav-item.on .prjnav-name", text: "web"
    assert_select ".prjnav-item.on .prjnav-repo", text: "pipihosting/pipi-web"
    # 1 chat + 1 event present; 0 runs omitted.
    assert_select ".prjnav-item.on .prjnav-stats", text: "1 chat · 1 event"
  end

  test "the edit form is admin-only" do
    project = shared_team_as_member.projects.create!(name: "Metis")
    get edit_project_path(project)
    assert_redirected_to team_path
  end
end
