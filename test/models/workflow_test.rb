require "test_helper"

class WorkflowTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "wf-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
  end

  test "name is required" do
    workflow = @team.workflows.new(name: "")
    refute workflow.valid?
    assert_includes workflow.errors[:name], "can't be blank"
  end

  test "defaults: manual trigger, enabled, empty steps" do
    workflow = @team.workflows.create!(name: "Triage")
    assert workflow.manual?
    assert workflow.enabled?
    assert_equal [], workflow.steps
    assert_equal({}, workflow.trigger_config)
  end

  test "name is unique per team case-insensitively" do
    @team.workflows.create!(name: "Ship")

    duplicate = @team.workflows.new(name: "ship")
    refute duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "same workflow name can exist on different teams" do
    @team.workflows.create!(name: "Ship")
    other = User.create!(email: "wf-other-#{SecureRandom.hex(4)}@example.com", password: "password123").personal_team

    assert other.workflows.create!(name: "ship")
  end

  test "name rejects newlines and has a bounded length" do
    newline = @team.workflows.new(name: "Ship\n## Inject")
    refute newline.valid?
    assert_includes newline.errors[:name], "is invalid"

    too_long = @team.workflows.new(name: "x" * (Workflow::NAME_MAX + 1))
    refute too_long.valid?
    assert_includes too_long.errors[:name], "is too long (maximum is #{Workflow::NAME_MAX} characters)"
  end

  test "enabled scope excludes disabled workflows" do
    on = @team.workflows.create!(name: "On")
    @team.workflows.create!(name: "Off", enabled: false)
    assert_equal [ on ], @team.workflows.enabled.to_a
  end

  test "steps and trigger_config round-trip as jsonb" do
    workflow = @team.workflows.create!(
      name: "Sentry",
      trigger_source: :webhook,
      trigger_config: { "source" => "sentry" },
      steps: [ { "key" => "spec", "name" => "Write spec", "prompt" => "...", "gate" => "auto" } ]
    )
    workflow.reload
    assert workflow.webhook?
    assert_equal "sentry", workflow.trigger_config["source"]
    assert_equal "spec", workflow.steps.first["key"]
  end

  test "destroying a workflow leaves its runs standing without the template" do
    workflow = @team.workflows.create!(name: "Triage")
    conversation = @user.conversations.create!
    run = @team.workflow_runs.create!(workflow: workflow, conversation: conversation)

    assert_no_difference -> { WorkflowRun.count } do
      workflow.destroy
    end
    assert_nil run.reload.workflow_id
  end

  test "destroying a team destroys its workflows" do
    other = User.create!(email: "wf-cascade-#{SecureRandom.hex(4)}@example.com", password: "password123").personal_team
    other.workflows.create!(name: "Will Cascade")

    assert_difference -> { Workflow.count }, -1 do
      other.destroy
    end
  end
end
