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

  test "index lists the team's projects with their about preview" do
    team.projects.create!(name: "Metis", about: "Rails 8.1 chat over pi.")

    get projects_path
    assert_response :success
    assert_select ".conn-name", text: "Metis"
    assert_select ".conn-sub", text: /Rails 8.1 chat over pi/
  end

  test "create persists name + about and stamps created_by / updated_by" do
    assert_difference -> { team.projects.count }, 1 do
      post projects_path, params: { project: { name: "Metis", about: "Rails 8.1 chat over pi." } }
    end
    project = team.projects.find_by!(name: "Metis")
    assert_equal "Rails 8.1 chat over pi.", project.about
    assert_equal @user.id, project.created_by_id
    assert_equal @user.id, project.updated_by_id
    assert_redirected_to edit_project_path(project)
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

  test "the edit form is admin-only" do
    project = shared_team_as_member.projects.create!(name: "Metis")
    get edit_project_path(project)
    assert_redirected_to team_path
  end
end
