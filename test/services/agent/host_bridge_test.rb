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
end
