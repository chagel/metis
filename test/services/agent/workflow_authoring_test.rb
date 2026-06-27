require "test_helper"

class Agent::WorkflowAuthoringTest < ActiveSupport::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @user = User.create!(email: "wa-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @project = @team.projects.create!(name: "Metis")
    @conversation = @user.conversations.create!(team: @team, project: @project)
  end

  def create(args)
    Agent::WorkflowAuthoring.create(@conversation, args)
  end

  def update(args)
    Agent::WorkflowAuthoring.update(@conversation, args)
  end

  test "creates a workflow from structured steps and returns the edit link" do
    result = nil
    assert_difference -> { Workflow.count }, 1 do
      result = create("name" => "Ship", "description" => "ship it",
                      "steps" => [ { "name" => "Build", "prompt" => "do the work" },
                                   { "name" => "Verify", "prompt" => "check it", "gate" => "approval", "run" => "local" } ])
    end

    workflow = Workflow.last
    assert_equal "Ship", workflow.name
    assert_equal "ship it", workflow.description
    assert_equal 2, workflow.steps.size
    assert_equal({ "name" => "Build", "prompt" => "do the work", "gate" => "auto", "run" => "cloud" }, workflow.steps.first)
    assert_equal "approval", workflow.steps.second["gate"]
    assert_equal "local", workflow.steps.second["run"]

    assert result[:ok]
    assert_equal "created", result[:action]
    assert_equal "Ship", result[:name]
    assert_equal edit_workflow_path(workflow), result[:url]
  end

  test "resolves a named default project" do
    create("name" => "Ship", "project" => "metis",
           "steps" => [ { "name" => "Build", "prompt" => "go" } ])
    assert_equal @project, Workflow.last.default_project
  end

  test "errors on an unknown project and creates nothing" do
    result = nil
    assert_no_difference -> { Workflow.count } do
      result = create("name" => "Ship", "project" => "ghost",
                      "steps" => [ { "name" => "Build", "prompt" => "go" } ])
    end
    refute result[:ok]
    assert_match(/project named "ghost"/, result[:error])
  end

  test "rejects a create with no steps" do
    result = nil
    assert_no_difference -> { Workflow.count } do
      result = create("name" => "Ship", "steps" => [])
    end
    refute result[:ok]
    assert_match(/at least one step/, result[:error])
  end

  test "rejects a step with a blank prompt via model validation" do
    result = nil
    assert_no_difference -> { Workflow.count } do
      result = create("name" => "Ship", "steps" => [ { "name" => "Build", "prompt" => "  " } ])
    end
    refute result[:ok]
    assert result[:error].present?
  end

  test "rejects a duplicate workflow name case-insensitively" do
    @team.workflows.create!(name: "Ship", steps: [ { "name" => "Build", "prompt" => "go" } ])

    result = nil
    assert_no_difference -> { Workflow.count } do
      result = create("name" => "ship", "steps" => [ { "name" => "Build", "prompt" => "go" } ])
    end
    refute result[:ok]
    assert_match(/name has already been taken/i, result[:error])
  end

  test "updates an existing workflow's steps, found by name case-insensitively" do
    workflow = @team.workflows.create!(name: "Ship", steps: [ { "name" => "old", "prompt" => "old", "gate" => "auto" } ])

    result = update("name" => "SHIP", "steps" => [ { "name" => "new", "prompt" => "new work" } ])

    assert_equal 1, workflow.reload.steps.size
    assert_equal "new work", workflow.steps.first["prompt"]
    assert result[:ok]
    assert_equal "updated", result[:action]
  end

  test "leaves omitted fields untouched on update" do
    workflow = @team.workflows.create!(
      name: "Ship", description: "keep me", default_project: @project,
      steps: [ { "name" => "s", "prompt" => "p", "gate" => "auto" } ]
    )

    update("name" => "Ship", "description" => "changed")

    workflow.reload
    assert_equal "changed", workflow.description
    assert_equal 1, workflow.steps.size, "steps left untouched when not passed"
    assert_equal @project, workflow.default_project
  end

  test "returns an error and changes nothing for an unknown workflow on update" do
    result = nil
    assert_no_difference -> { Workflow.count } do
      result = update("name" => "ghost", "description" => "x")
    end
    refute result[:ok]
    assert_match(/no workflow named "ghost"/i, result[:error])
  end

  test "refuses authoring for a non-admin member" do
    member = User.create!(email: "m-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team.memberships.create!(user: member, role: :member)
    convo = member.conversations.create!(team: @team, project: @project)

    result = nil
    assert_no_difference -> { Workflow.count } do
      result = Agent::WorkflowAuthoring.create(convo, "name" => "Ship", "steps" => [ { "name" => "b", "prompt" => "go" } ])
    end
    refute result[:ok]
    assert_match(/team admins/i, result[:error])
  end

  test "refuses to author from inside a workflow run" do
    run = WorkflowRun.start(
      team: @team, user: @user, project: @project,
      steps: [ { "name" => "s", "prompt" => "p", "gate" => "auto" } ]
    )
    result = nil
    assert_no_difference -> { Workflow.count } do
      result = Agent::WorkflowAuthoring.create(run.conversation, "name" => "X", "steps" => [ { "name" => "b", "prompt" => "go" } ])
    end
    refute result[:ok]
    assert_match(/inside a workflow run/i, result[:error])
  end
end
