require "test_helper"

class Agent::WorkflowHandoffTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Rails.application.routes.url_helpers

  setup do
    @user = User.create!(email: "wh-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @project = @team.projects.create!(name: "Metis")
    @workflow = @team.workflows.create!(
      name: "Ship", enabled: true,
      steps: [ { "name" => "build", "prompt" => "do the work", "gate" => "auto" } ]
    )
    @conversation = @user.conversations.create!(team: @team, project: @project)
    @conversation.messages.create!(role: :user, content: "let's design the widget", streaming_status: :done)
    @conversation.messages.create!(role: :assistant, content: "here is the spec we agreed", streaming_status: :done)
    # The turn that triggered the handoff; replayable_history excludes it.
    @conversation.messages.create!(role: :user, content: "start the ship workflow", streaming_status: :done)
  end

  # WorkflowRun.start enqueues WorkflowAdvanceJob; leave it enqueued — running
  # it would launch a real agent turn. We only assert the handoff's own work.
  def handoff(args)
    Agent::WorkflowHandoff.from_tool_call(@conversation, args)
  end

  test "queues a run for a named workflow, seeded with the chat, and returns the link" do
    result = nil
    assert_difference -> { WorkflowRun.count }, 1 do
      result = handoff("workflow" => "ship", "project" => "metis", "note" => "build the widget")
    end

    run = WorkflowRun.last
    assert run.queued?, "chat handoffs queue rather than start immediately"
    assert_equal @workflow, run.workflow
    assert_equal @project, run.conversation.project
    assert_equal "build the widget", run.conversation.title, "the note titles the queued run"
    assert_includes run.input, "build the widget"
    assert_includes run.input, "here is the spec we agreed"

    assert result[:ok]
    assert_equal "Ship", result[:workflow]
    assert_equal "Metis", result[:project]
    assert_equal conversation_path(run.conversation), result[:url]
  end

  test "falls back to the workflow name for the title when no note is given" do
    handoff("workflow" => "ship")
    assert_equal "Ship workflow", WorkflowRun.last.conversation.title
  end

  test "appends download links for the chat's artifacts to the run input" do
    msg = @conversation.messages.create!(role: :assistant, content: "shipped the spec", streaming_status: :done)
    msg.artifacts.attach(io: StringIO.new("# spec"), filename: "fifa-spec.md", content_type: "text/markdown")

    handoff("workflow" => "ship")

    input = WorkflowRun.last.input
    assert_includes input, "fifa-spec.md"
    assert_includes input, "/files/blobs/redirect/", "carries the durable Active Storage download URL"
    assert_includes input, "download", "tells the run to fetch them, tool-agnostic"
  end

  test "the queued run is not advanced until launched" do
    assert_no_enqueued_jobs(only: WorkflowAdvanceJob) do
      handoff("workflow" => "ship")
    end
  end

  test "name matching is case-insensitive" do
    assert_difference -> { WorkflowRun.count }, 1 do
      handoff("workflow" => "SHIP")
    end
  end

  test "falls back to the chat's project when none is named" do
    handoff("workflow" => "ship")
    assert_equal @project, WorkflowRun.last.conversation.project
  end

  test "returns an error and starts nothing when the workflow name is unknown" do
    result = nil
    assert_no_difference -> { WorkflowRun.count } do
      result = handoff("workflow" => "nope")
    end
    refute result[:ok]
    assert_match(/no enabled workflow/i, result[:error])
  end

  test "ignores a disabled workflow" do
    @workflow.update!(enabled: false)
    result = nil
    assert_no_difference -> { WorkflowRun.count } do
      result = handoff("workflow" => "ship")
    end
    refute result[:ok]
  end

  test "refuses to spawn from a conversation that is itself a workflow run" do
    run = WorkflowRun.start(team: @team, user: @user, workflow: @workflow, project: @project)
    result = nil
    assert_no_difference -> { WorkflowRun.count } do
      result = Agent::WorkflowHandoff.from_tool_call(run.conversation, "workflow" => "ship")
    end
    refute result[:ok]
    assert_match(/inside a workflow run/i, result[:error])
  end

  test "errors when no project can be resolved" do
    @conversation.update!(project: nil)
    result = nil
    assert_no_difference -> { WorkflowRun.count } do
      result = handoff("workflow" => "ship")
    end
    refute result[:ok]
    assert_match(/name a project/i, result[:error])
  end
end
