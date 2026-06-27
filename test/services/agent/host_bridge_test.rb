require "test_helper"

class Agent::HostBridgeTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "hb-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @project = @team.projects.create!(name: "Metis")
    @workflow = @team.workflows.create!(
      name: "Ship", description: "ship it", default_project: @project,
      steps: [ { "name" => "Build", "prompt" => "do the work", "gate" => "auto", "run" => "cloud" },
               { "name" => "Review", "prompt" => "check it", "gate" => "approval", "run" => "local" } ]
    )
    @conversation = @user.conversations.create!(team: @team, project: @project)
  end

  # A stand-in for PiAgent::ExtensionUI::Request (title + placeholder).
  Req = Struct.new(:title, :placeholder)

  test "get_workflow returns the full definition as JSON" do
    json = Agent::HostBridge.call(@conversation, "get_workflow", "name" => "Ship")
    wf = JSON.parse(json)

    assert_equal "Ship", wf["name"]
    assert_equal "ship it", wf["description"]
    assert_equal true, wf["enabled"]
    assert_equal "Metis", wf["default_project"]
    assert_equal 2, wf["steps"].size
    assert_equal "approval", wf["steps"].last["gate"]
    assert_equal "local", wf["steps"].last["run"]
  end

  test "get_workflow matches name case-insensitively" do
    assert Agent::HostBridge.call(@conversation, "get_workflow", "name" => "SHIP")
  end

  test "returns nil for an unknown workflow" do
    assert_nil Agent::HostBridge.call(@conversation, "get_workflow", "name" => "ghost")
  end

  test "is team-scoped — a workflow on another team is invisible" do
    other = User.create!(email: "hb-other-#{SecureRandom.hex(4)}@example.com", password: "password123")
    other.personal_team.workflows.create!(name: "Secret", steps: [ { "name" => "s", "prompt" => "p", "gate" => "auto" } ])

    assert_nil Agent::HostBridge.call(@conversation, "get_workflow", "name" => "Secret")
  end

  test "get_project returns detail and bound external resources as JSON" do
    @project.update!(about: "the app", github_repo: "chagel/metis", linear_project: "abc12345-0000-0000-0000-000000000000")
    json = Agent::HostBridge.call(@conversation, "get_project", "name" => "Metis")
    p = JSON.parse(json)

    assert_equal "Metis", p["name"]
    assert_equal "the app", p["about"]
    assert_equal "chagel/metis", p["github_repo"]
    assert_equal "abc12345-0000-0000-0000-000000000000", p["linear_project"]
  end

  test "get_project returns nil for an unknown project" do
    assert_nil Agent::HostBridge.call(@conversation, "get_project", "name" => "ghost")
  end

  test "get_project is team-scoped" do
    other = User.create!(email: "hb-p-#{SecureRandom.hex(4)}@example.com", password: "password123")
    other.personal_team.projects.create!(name: "Hidden")
    assert_nil Agent::HostBridge.call(@conversation, "get_project", "name" => "Hidden")
  end

  test "rejects an op that isn't on the allowlist" do
    assert_nil Agent::HostBridge.call(@conversation, "delete_workflow", "name" => "Ship")
    assert_nil Agent::HostBridge.call(@conversation, "evil", {})
  end

  test "the handler services metis:-prefixed requests and parses JSON params" do
    handler = Agent::HostBridge.handler(@conversation)
    json = handler.call(Req.new("metis:get_workflow", JSON.generate(name: "Ship")))
    assert_equal "Ship", JSON.parse(json)["name"]
  end

  test "the handler cancels non-metis (genuine user) dialogs" do
    handler = Agent::HostBridge.handler(@conversation)
    assert_nil handler.call(Req.new("Pick a file", "options"))
  end

  test "the handler tolerates malformed params, falling back to empty" do
    handler = Agent::HostBridge.handler(@conversation)
    assert_nil handler.call(Req.new("metis:get_workflow", "not json")), "no name → no match → nil"
  end

  # --- write ops -----------------------------------------------------

  test "create_workflow persists and returns an ok result as JSON" do
    json = nil
    assert_difference -> { Workflow.count }, 1 do
      json = Agent::HostBridge.call(@conversation, "create_workflow",
                                    "name" => "Greet", "steps" => [ { "name" => "Hi", "prompt" => "say hi" } ])
    end
    res = JSON.parse(json)
    assert_equal true, res["ok"]
    assert_equal "created", res["action"]
    assert res["url"].present?
  end

  test "update_workflow edits an existing workflow" do
    workflow = @team.workflows.create!(name: "Greet", steps: [ { "name" => "old", "prompt" => "old", "gate" => "auto" } ])
    json = Agent::HostBridge.call(@conversation, "update_workflow",
                                  "name" => "Greet", "steps" => [ { "name" => "new", "prompt" => "new" } ])
    assert_equal true, JSON.parse(json)["ok"]
    assert_equal "new", workflow.reload.steps.first["prompt"]
  end

  test "start_workflow queues a run and returns the link" do
    json = nil
    assert_difference -> { WorkflowRun.count }, 1 do
      json = Agent::HostBridge.call(@conversation, "start_workflow", "workflow" => "Ship")
    end
    res = JSON.parse(json)
    assert_equal true, res["ok"]
    assert res["url"].present?
  end

  test "write ops surface failures as ok:false rather than raising" do
    json = Agent::HostBridge.call(@conversation, "update_workflow", "name" => "ghost")
    res = JSON.parse(json)
    assert_equal false, res["ok"]
    assert res["error"].present?
  end

  test "the handler routes write ops too" do
    handler = Agent::HostBridge.handler(@conversation)
    json = handler.call(Req.new("metis:create_workflow",
                                JSON.generate(name: "Greet", steps: [ { name: "Hi", prompt: "say hi" } ])))
    assert_equal true, JSON.parse(json)["ok"]
  end

  # --- skill ops -----------------------------------------------------

  test "list_skills returns built-in and team skills with status as JSON" do
    @team.skills.create!(slug: "team-thing", description: "ours", enabled: false, content_cache: "x")
    skills = JSON.parse(Agent::HostBridge.call(@conversation, "list_skills", {}))

    assert skills.any? { |s| s["source"] == "builtin" && s["status"] == "built-in" }
    team = skills.find { |s| s["slug"] == "team-thing" }
    assert_equal "disabled", team["status"]
  end

  test "create_skill creates a team skill via the bridge" do
    content = "---\nname: code-review\ndescription: review\n---\n\nBody."
    json = nil
    assert_difference -> { Skill.count }, 1 do
      json = Agent::HostBridge.call(@conversation, "create_skill", "slug" => "code-review", "content" => content)
    end
    assert_equal true, JSON.parse(json)["ok"]
  end

  test "update_skill toggles enabled via the bridge" do
    skill = @team.skills.create!(slug: "code-review", enabled: true, content_cache: "x")
    json = Agent::HostBridge.call(@conversation, "update_skill", "slug" => "code-review", "enabled" => false)
    assert_equal true, JSON.parse(json)["ok"]
    refute skill.reload.enabled?
  end
end
