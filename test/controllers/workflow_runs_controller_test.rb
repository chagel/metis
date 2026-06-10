require "test_helper"

class WorkflowRunsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "wfc-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    sign_in @user
  end

  # Build a run already paused at a gate, without driving the engine.
  def gated_run
    conversation = @user.conversations.create!
    run = @team.workflow_runs.create!(conversation: conversation, status: :awaiting_approval)
    msg = conversation.messages.create!(role: :assistant, content: "the spec", streaming_status: :done)
    run.tasks.create!(position: 0, name: "spec", gate: :auto, status: :completed, assistant_message: msg)
    run.tasks.create!(position: 1, name: "review", gate: :approval, status: :awaiting_approval)
    run
  end

  def shared_team
    team = Team.create!(name: "Acme")
    team.memberships.create!(user: @user, role: :owner)
    team
  end

  # Sign in a fresh member of `team` and switch their session into it.
  def join_as_teammate(team)
    mate = User.create!(email: "mate-#{SecureRandom.hex(4)}@example.com", password: "password123")
    team.memberships.create!(user: mate, role: :member)
    sign_in mate
    post switch_team_path(team)
  end

  test "a team-visible run opens read-only for a teammate; personal stays private" do
    team = shared_team
    open_run = WorkflowRun.start(team: team, user: @user, visibility: :team,
                                 steps: [ { "name" => "a", "prompt" => "a" } ])
    private_run = WorkflowRun.start(team: team, user: @user,
                                    steps: [ { "name" => "a", "prompt" => "a" } ])
    assert private_run.conversation.visibility_personal?, "personal is the default"

    join_as_teammate(team)
    get conversation_path(open_run.conversation)
    assert_response :success
    assert_match "Read-only", response.body

    get conversation_path(private_run.conversation)
    assert_response :not_found
  end

  test "a teammate cannot act on a personal run's gate" do
    team = shared_team
    conversation = @user.conversations.create!(team: team)
    run = team.workflow_runs.create!(conversation: conversation, status: :awaiting_approval)
    run.tasks.create!(position: 0, gate: :approval, status: :awaiting_approval)

    join_as_teammate(team)
    post approve_workflow_run_path(run), as: :turbo_stream
    assert_response :not_found
    assert run.reload.awaiting_approval?

    conversation.update!(visibility: :team)
    post approve_workflow_run_path(run), as: :turbo_stream
    assert_response :success
    assert run.reload.running?
  end

  test "the composer's visibility pick reaches the run conversation" do
    workflow = @team.workflows.create!(name: "W", steps: [ { "name" => "a", "prompt" => "a" } ])
    post workflow_runs_path, params: { workflow_id: workflow.id, content: "go", visibility: "team" }
    assert WorkflowRun.order(:id).last.conversation.visibility_team?
  end

  test "an awaiting run pins in a teammate's sidebar and shared tab" do
    team = shared_team
    conversation = @user.conversations.create!(team: team, visibility: :team, title: "ZZ team run")
    run = team.workflow_runs.create!(conversation: conversation, status: :awaiting_approval)
    run.tasks.create!(position: 0, gate: :approval, status: :awaiting_approval)

    join_as_teammate(team)
    get conversations_path
    assert_select ".convos-pinned .convo", text: /team run/i
    get conversations_path(filter: "team")
    assert_select "#convos-list .convo", text: /team run/i
  end

  test "the run note names the claimer once a delegated task is claimed" do
    conversation = @user.conversations.create!(team: @team)
    run = @team.workflow_runs.create!(conversation: conversation, status: :awaiting_local)
    task = run.tasks.create!(position: 0, name: "impl", status: :running, delegated: true)

    get conversation_path(conversation)
    assert_match "waiting for a machine with a bridge token", response.body
    assert_match "Waiting for a machine", response.body

    task.update!(claimed_by_user: @user, claimed_by: "Apollo")
    get conversation_path(conversation)
    assert_match "#{@user.display_label}&#39;s Apollo is working on this step", response.body
    assert_match "On #{@user.display_label}&#39;s machine", response.body
  end

  test "the gate on the final step reads finish, mid-run reads continue" do
    run = gated_run
    get conversation_path(run.conversation)
    assert_select ".wf-gate .btn-primary", text: "Approve & finish"
    assert_match "your sign-off completes the run", response.body

    run.tasks.create!(position: 2, name: "ship", gate: :auto, status: :pending)
    get conversation_path(run.conversation)
    assert_select ".wf-gate .btn-primary", text: "Approve & continue"
  end

  test "the sidebar pins awaiting-approval runs and lifts them out of the recency list" do
    @user.conversations.create!(title: "ZZ normal chat")
    gated = @user.conversations.create!(title: "ZZ gated run")
    run = @team.workflow_runs.create!(conversation: gated, status: :awaiting_approval)
    run.tasks.create!(position: 0, gate: :approval, status: :awaiting_approval)

    get conversations_path
    assert_response :success
    assert_select ".convos-pinned .convo", text: /gated run/i
    # pinned, not duplicated in the recency list
    assert_select "#convos-list .convo", text: /gated run/i, count: 0
    assert_select "#convos-list .convo", text: /normal chat/i
  end

  test "the new-chat composer feeds workflows to the slash-command palette" do
    @team.workflows.create!(name: "Triage", steps: [ { "name" => "a", "prompt" => "a", "gate" => "auto" } ])
    get conversations_path
    assert_response :success
    # Workflows ride in the skill-palette controller's data value (the popup
    # is rendered client-side from it) and the form wires the launch event.
    assert_select "[data-skill-palette-workflows-value*=?]", "Triage"
    assert_select "form[data-action*=?]", "workflow-launch#selectFromPalette"
  end

  test "create launches a run, folds input into step 1, and lands on its conversation" do
    project = @team.projects.create!(name: "R&D")
    workflow = @team.workflows.create!(
      name: "Triage", default_project: project,
      steps: [ { "name" => "spec", "prompt" => "write the spec", "gate" => "approval" } ]
    )

    assert_difference -> { WorkflowRun.count }, 1 do
      assert_enqueued_with(job: WorkflowAdvanceJob) do
        post workflow_runs_path(workflow_id: workflow.id, input: "for the launch composer feature")
      end
    end

    run = WorkflowRun.last
    assert_equal workflow, run.workflow
    assert_equal project, run.conversation.project
    first = run.tasks.first
    assert_match "for the launch composer feature", first.prompt
    assert_match "write the spec", first.prompt
    assert_redirected_to run.conversation
  end

  test "create from the composer uses the typed content as input and the picked model" do
    workflow = @team.workflows.create!(
      name: "Triage", steps: [ { "name" => "spec", "prompt" => "write the spec", "gate" => "approval" } ]
    )
    # The composer posts `content` (not `input`) alongside workflow_id + model.
    post workflow_runs_path(workflow_id: workflow.id, content: "the launch composer", model: "claude-opus-4-8")
    run = WorkflowRun.last
    assert_match "the launch composer", run.tasks.first.prompt
    assert_equal "claude-opus-4-8", run.conversation.settings["model"]
    assert_redirected_to run.conversation
  end

  test "create honors a project override" do
    other = @team.projects.create!(name: "Override")
    workflow = @team.workflows.create!(name: "W", steps: [ { "name" => "a", "prompt" => "a", "gate" => "auto" } ])
    post workflow_runs_path(workflow_id: workflow.id, project_id: other.id)
    assert_equal other, WorkflowRun.last.conversation.project
  end

  test "approve completes the gate, resumes the run, and enqueues an advance" do
    run = gated_run
    assert_enqueued_with(job: WorkflowAdvanceJob) do
      post approve_workflow_run_path(run), as: :turbo_stream
    end
    assert_response :success
    assert run.reload.running?
    gate = run.tasks.find_by(position: 1)
    assert gate.completed?
    assert_equal @user, gate.approved_by
    review = run.conversation.messages.where(kind: :review).last
    assert_equal %(#{@user.display_label} approved "review"), review.content
  end

  test "reject cancels the run" do
    run = gated_run
    post reject_workflow_run_path(run), as: :turbo_stream
    assert_response :success
    assert run.reload.cancelled?
    assert run.tasks.find_by(position: 1).rejected?
  end

  test "request_changes re-runs the gated step with the feedback" do
    run = gated_run
    post request_changes_workflow_run_path(run), params: { feedback: "open a PR too" }, as: :turbo_stream
    assert_response :success
    assert run.reload.running?
    assert run.tasks.find_by(position: 1).running?
    feedback = run.conversation.messages.user.order(:created_at).last
    assert feedback.review?
    assert_equal "#{@user.display_label} requested changes — open a PR too", feedback.content
  end

  test "an injected step prompt renders as a step instruction, not a user bubble" do
    run = gated_run
    run.conversation.messages.create!(
      role: :user, content: "implement the spec", streaming_status: :done, kind: :step_prompt
    )
    get conversation_path(run.conversation)
    assert_response :success
    assert_select ".msg-step", text: /implement the spec/
    assert_select ".msg-user .bubble", text: /implement the spec/, count: 0
  end

  test "a run in another team is not reachable" do
    run = gated_run
    sign_out @user
    sign_in User.create!(email: "wfc-out-#{SecureRandom.hex(4)}@example.com", password: "password123")
    post approve_workflow_run_path(run), as: :turbo_stream
    assert_response :not_found
    assert run.reload.awaiting_approval?
  end

  test "the conversation view renders the rail and the gate card" do
    run = gated_run
    get conversation_path(run.conversation)
    assert_response :success
    assert_select "#workflow_rail"
    assert_select "#workflow_gate"
    assert_match "Review needed", response.body
    assert_match "the spec", response.body
  end
end
