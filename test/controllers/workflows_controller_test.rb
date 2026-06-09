require "test_helper"

class WorkflowsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "wfsettings-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    sign_in @user
  end

  test "index lists templates" do
    @team.workflows.create!(name: "Triage")
    get workflows_path
    assert_response :success
    assert_match "Triage", response.body
  end

  test "create normalizes steps and drops blank rows" do
    assert_difference -> { @team.workflows.count }, 1 do
      post workflows_path, params: { workflow: {
        name: "Sentry fix",
        steps: {
          "0" => { name: "spec", prompt: "write spec", gate: "auto" },
          "1" => { name: "review", prompt: "review it", gate: "approval" },
          "2" => { name: "", prompt: "", gate: "auto" } # blank → dropped
        }
      } }
    end
    workflow = @team.workflows.find_by(name: "Sentry fix")
    assert_redirected_to edit_workflow_path(workflow)
    assert_equal 2, workflow.steps.size
    assert_equal %w[spec review], workflow.steps.map { |s| s["name"] }
    assert_equal "approval", workflow.steps.last["gate"]
  end

  test "update edits steps" do
    workflow = @team.workflows.create!(name: "W", steps: [ { "name" => "a", "prompt" => "a", "gate" => "auto" } ])
    patch workflow_path(workflow), params: { workflow: {
      name: "W", steps: { "0" => { name: "b", prompt: "do b", gate: "approval" } }
    } }
    assert_redirected_to edit_workflow_path(workflow)
    workflow.reload
    assert_equal [ "b" ], workflow.steps.map { |s| s["name"] }
    assert_equal "approval", workflow.steps.first["gate"]
  end

  test "a step without a prompt is rejected" do
    post workflows_path, params: { workflow: {
      name: "Bad", steps: { "0" => { name: "say hi again", prompt: "", gate: "approval" } }
    } }
    assert_response :unprocessable_entity
    assert_equal 0, @team.workflows.where(name: "Bad").count
  end

  test "a default project from another team is rejected" do
    other_project = User.create!(email: "wf-proj-#{SecureRandom.hex(4)}@example.com", password: "password123")
                        .personal_team.projects.create!(name: "Foreign")
    post workflows_path, params: { workflow: { name: "X", default_project_id: other_project.id } }
    assert_response :unprocessable_entity
  end

  test "new renders the editor" do
    get new_workflow_path
    assert_response :success
    assert_select "[data-controller='workflow-editor']"
    assert_select "template[data-workflow-editor-target='template']"
  end

  test "edit renders existing steps" do
    workflow = @team.workflows.create!(
      name: "W", steps: [ { "name" => "spec", "prompt" => "do it", "gate" => "approval" } ]
    )
    get edit_workflow_path(workflow)
    assert_response :success
    # Scope past the inert <template> row to the live list.
    assert_select ".wf-steps-list [data-workflow-editor-target='row']", 1
    assert_match "spec", response.body
  end

  test "destroy removes the workflow" do
    workflow = @team.workflows.create!(name: "Doomed")
    assert_difference -> { @team.workflows.count }, -1 do
      delete workflow_path(workflow)
    end
    assert_redirected_to workflows_path
  end
end
