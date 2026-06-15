require "test_helper"

class WorkflowRunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "wfr-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
  end

  def new_run(**attrs)
    conversation = attrs.delete(:conversation) || @user.conversations.create!
    @team.workflow_runs.create!(conversation: conversation, **attrs)
  end

  test "defaults to pending" do
    assert new_run.pending?
  end

  test "active scope spans pending, running, awaiting_approval only" do
    pending  = new_run
    running  = new_run.tap(&:running!)
    awaiting = new_run.tap(&:awaiting_approval!)
    new_run.tap(&:completed!)
    new_run.tap(&:cancelled!)

    assert_equal [ pending, running, awaiting ].map(&:id).sort,
                 @team.workflow_runs.active.pluck(:id).sort
  end

  test "awaiting scope returns only gated runs" do
    new_run
    awaiting = new_run.tap(&:awaiting_approval!)
    assert_equal [ awaiting ], @team.workflow_runs.awaiting.to_a
  end

  test "one run per conversation" do
    conversation = @user.conversations.create!
    new_run(conversation: conversation)
    assert_raises(ActiveRecord::RecordNotUnique) do
      # Skip the model uniqueness path to prove the DB index enforces it.
      @team.workflow_runs.create!(conversation_id: conversation.id)
    end
  end

  test "conversation exposes its run via has_one" do
    conversation = @user.conversations.create!
    run = new_run(conversation: conversation)
    assert_equal run, conversation.reload.workflow_run
  end

  test "destroying the conversation destroys the run" do
    conversation = @user.conversations.create!
    new_run(conversation: conversation)
    assert_difference -> { WorkflowRun.count }, -1 do
      conversation.destroy
    end
  end

  test "workflow is optional (ad-hoc run)" do
    assert new_run(workflow: nil).valid?
  end

  test ".start builds the conversation, tasks, and an active run in a project" do
    project = @team.projects.create!(name: "R&D")
    workflow = @team.workflows.create!(name: "Triage")
    run = WorkflowRun.start(
      team: @team, user: @user, workflow: workflow, project: project,
      steps: [
        { "name" => "spec", "prompt" => "write spec", "gate" => "auto" },
        { "name" => "review", "gate" => "approval" }
      ]
    )

    assert run.pending?
    assert_equal project, run.conversation.project
    assert_nil run.conversation.title, "untitled at start so auto-titling can name it from the first turn"
    assert_equal @user, run.conversation.user
    assert_equal %w[spec review], run.tasks.map(&:name)
    assert run.tasks.first.auto?
    assert run.tasks.second.approval?
  end

  test ".start titles the conversation when a title is given" do
    run = WorkflowRun.start(team: @team, user: @user, title: "My run",
                            project: @team.projects.create!(name: "Titled"),
                            steps: [ { "name" => "a", "prompt" => "a" } ])
    assert_equal "My run", run.conversation.title
  end

  test ".start defaults to a workflow's own steps" do
    workflow = @team.workflows.create!(
      name: "Two-step",
      steps: [ { "name" => "a", "prompt" => "a", "gate" => "auto" },
               { "name" => "b", "prompt" => "b", "gate" => "auto" } ]
    )
    run = WorkflowRun.start(team: @team, user: @user, workflow: workflow,
                            project: @team.projects.create!(name: "Defaults"))
    assert_equal 2, run.tasks.count
  end

  test ".start refuses a nil project" do
    assert_raises ArgumentError do
      WorkflowRun.start(team: @team, user: @user, project: nil,
                        steps: [ { "name" => "a", "prompt" => "a" } ])
    end
  end

  test ".start with autostart false queues the run and advances nothing" do
    project = @team.projects.create!(name: "Queued")
    run = nil
    assert_no_enqueued_jobs(only: WorkflowAdvanceJob) do
      run = WorkflowRun.start(team: @team, user: @user, project: project,
                              steps: [ { "name" => "a", "prompt" => "a" } ], autostart: false)
    end
    assert run.queued?
    assert run.tasks.any?, "tasks are still built up front"
  end

  test "#launch! starts a queued run and enqueues the advance job" do
    project = @team.projects.create!(name: "Launch")
    run = WorkflowRun.start(team: @team, user: @user, project: project,
                            steps: [ { "name" => "a", "prompt" => "a" } ], autostart: false)

    assert_enqueued_with(job: WorkflowAdvanceJob) { assert run.launch! }
    assert run.pending?
  end

  test "#launch! is a no-op on a run that has already left the queue" do
    run = new_run.tap(&:running!)
    assert_no_enqueued_jobs(only: WorkflowAdvanceJob) do
      assert_not run.launch!
    end
    assert run.running?
  end

  test "active and awaiting scopes include queued runs" do
    queued = new_run.tap(&:queued!)
    assert_includes @team.workflow_runs.active, queued
    assert_includes @team.workflow_runs.awaiting, queued
  end

  test ".signal_turn_finished enqueues an advance only for an active run" do
    conversation = @user.conversations.create!
    run = new_run(conversation: conversation)

    assert_enqueued_with(job: WorkflowAdvanceJob) do
      WorkflowRun.signal_turn_finished(conversation.reload)
    end

    run.completed!
    assert_no_enqueued_jobs(only: WorkflowAdvanceJob) do
      WorkflowRun.signal_turn_finished(conversation.reload)
    end
  end
end
