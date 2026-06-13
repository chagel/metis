require "test_helper"

class Api::Bridge::TasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "abt-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @token = @user.generate_bridge_token!
  end

  def auth = { "Authorization" => "Bearer #{@token}" }

  test "claim returns the dispatched task, stamps presence and client name" do
    run = dispatch_run
    get "/api/bridge/tasks/next", headers: auth.merge("X-Bridge-Client" => "mikes-mbp")
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal run.tasks.first.id, body["task_id"]
    assert_equal "implement", body["prompt"]
    assert_equal "mikes-mbp", run.tasks.first.reload.claimed_by
    assert @user.reload.bridge_seen_at.present?
    assert_equal "mikes-mbp", @user.bridge_client
  end

  test "claim returns 204 when nothing is dispatched" do
    get "/api/bridge/tasks/next", headers: auth
    assert_response :no_content
  end

  test "claim payload carries prior steps' full content and artifact urls" do
    run = WorkflowRun.start(team: @team, user: @user,
                            project: @team.projects.create!(name: "Payloads"), steps: [
      { "name" => "spec", "prompt" => "write the spec" }, LOCAL_STEP
    ])
    WorkflowAdvanceJob.perform_now(run.id)        # starts the cloud spec step
    spec = run.tasks.find_by(position: 0)
    long_content = "## Spec\n#{"All the details. " * 60}"   # > the old 400-char cap
    spec.assistant_message.update!(content: long_content, streaming_status: :done)
    spec.assistant_message.artifacts.attach(
      io: StringIO.new("# Spec file"), filename: "spec.md", content_type: "text/markdown"
    )
    WorkflowAdvanceJob.perform_now(run.id)        # settles spec, dispatches the local step

    get "/api/bridge/tasks/next", headers: auth
    assert_response :success
    prior = JSON.parse(response.body).dig("context", "prior_steps").first
    assert_equal "spec", prior["name"]
    assert_equal long_content, prior["content"], "full content, untruncated"
    assert_equal "spec.md", prior["artifacts"].first["name"]
    assert_match %r{^http.+/files/blobs/}, prior["artifacts"].first["url"]
  end

  test "claim payload carries the run input so a later step knows the subject" do
    run = WorkflowRun.start(team: @team, user: @user, input: "review pr 75",
                            project: @team.projects.create!(name: "Subject"), steps: [ LOCAL_STEP ])
    WorkflowAdvanceJob.perform_now(run.id)

    get "/api/bridge/tasks/next", headers: auth
    assert_response :success
    assert_equal "review pr 75", JSON.parse(response.body).dig("context", "input")
  end

  test "claim payload omits input when the run has none" do
    dispatch_run
    get "/api/bridge/tasks/next", headers: auth
    assert_response :success
    assert_not_includes JSON.parse(response.body)["context"].keys, "input"
  end

  test "index lists the claim queue without claiming" do
    workflow = @team.workflows.create!(name: "Ship it", steps: [ LOCAL_STEP ])
    run = WorkflowRun.start(team: @team, user: @user, workflow: workflow,
                            project: @team.projects.create!(name: "Queue"))
    WorkflowAdvanceJob.perform_now(run.id)

    get "/api/bridge/tasks", headers: auth
    assert_response :success
    tasks = JSON.parse(response.body)["tasks"]
    assert_equal [ run.tasks.first.id ], tasks.map { |t| t["task_id"] }
    assert_equal "impl", tasks.first["name"]
    assert_equal "Ship it", tasks.first["workflow"]
    assert_nil run.tasks.first.reload.claimed_by, "listing must not claim"
  end

  test "index exposes the user's auto-claim preference for the daemon" do
    get "/api/bridge/tasks", headers: auth
    assert_equal true, JSON.parse(response.body)["auto_claim"], "auto is the default"

    @user.update!(auto_claim_tasks: false)
    get "/api/bridge/tasks", headers: auth
    assert_equal false, JSON.parse(response.body)["auto_claim"]
  end

  test "manual mode refuses the daemon's blind claim but honors id-scoped picks" do
    run = dispatch_run
    @user.update!(auto_claim_tasks: false)

    get "/api/bridge/tasks/next", headers: auth
    assert_response :no_content, "a blind FIFO poll claims nothing in manual mode"
    get "/api/bridge/tasks/next", params: { project: "any" }, headers: auth
    assert_response :no_content, "a blind project-scoped poll is also refused"
    assert_nil run.tasks.first.reload.claimed_by, "manual mode left the task in the queue"

    get "/api/bridge/tasks/next", params: { id: run.tasks.first.id }, headers: auth
    assert_response :success, "a deliberate id-scoped pick still works in manual mode"
    assert_equal run.tasks.first.id, JSON.parse(response.body)["task_id"]
  end

  test "auto mode claims blindly by default" do
    run = dispatch_run
    assert @user.auto_claim_tasks, "auto is the default"
    get "/api/bridge/tasks/next", headers: auth
    assert_response :success
    assert_equal run.tasks.first.id, JSON.parse(response.body)["task_id"]
  end

  test "index excludes claimed tasks and other teams' tasks" do
    dispatch_run
    Task.claim_next_for(@user)
    stranger = User.create!(email: "z-#{SecureRandom.hex(4)}@example.com", password: "password123")
    get "/api/bridge/tasks", headers: { "Authorization" => "Bearer #{stranger.generate_bridge_token!}" }
    assert_equal [], JSON.parse(response.body)["tasks"]
    get "/api/bridge/tasks", headers: auth
    assert_equal [], JSON.parse(response.body)["tasks"]
  end

  test "claim with id picks that task over the older one" do
    older = dispatch_run
    newer = dispatch_run
    target = newer.tasks.first
    get "/api/bridge/tasks/next", params: { id: target.id }, headers: auth
    assert_response :success
    assert_equal target.id, JSON.parse(response.body)["task_id"]
    assert_nil older.tasks.first.reload.claimed_by
  end

  test "tasks carry a ref, claimable and reportable by it" do
    run = dispatch_run
    task = run.tasks.first
    get "/api/bridge/tasks", headers: auth
    ref = JSON.parse(response.body)["tasks"].first["ref"]
    assert_equal task.ref, ref
    assert_match(/\ARUN-[0-9A-Z]+\z/, ref)

    get "/api/bridge/tasks/next", params: { id: ref }, headers: auth
    assert_response :success
    assert_equal task.id, JSON.parse(response.body)["task_id"]

    post "/api/bridge/tasks/#{ref}/result",
         params: { status: "completed", summary: "done by ref" }, headers: auth
    assert_response :ok
    assert task.reload.completed?
  end

  test "claim with an unavailable id returns 409" do
    run = dispatch_run
    Task.claim_next_for(@user)   # someone else got there first
    get "/api/bridge/tasks/next", params: { id: run.tasks.first.id }, headers: auth
    assert_response :conflict
  end

  test "a personal run's task is invisible to teammates; team-visible stays pooled" do
    team = Team.create!(name: "Acme")
    team.memberships.create!(user: @user, role: :owner)
    mate = User.create!(email: "mate-#{SecureRandom.hex(4)}@example.com", password: "password123")
    team.memberships.create!(user: mate, role: :member)

    project = team.projects.create!(name: "Shared")
    personal = WorkflowRun.start(team: team, user: @user, project: project, steps: [ LOCAL_STEP ])
    WorkflowAdvanceJob.perform_now(personal.id)
    shared = WorkflowRun.start(team: team, user: @user, project: project, steps: [ LOCAL_STEP ], visibility: :team)
    WorkflowAdvanceJob.perform_now(shared.id)

    mate_auth = { "Authorization" => "Bearer #{mate.generate_bridge_token!}" }
    get "/api/bridge/tasks", headers: mate_auth
    ids = JSON.parse(response.body)["tasks"].map { |t| t["task_id"] }
    assert_equal [ shared.tasks.first.id ], ids, "only the team-visible task is listed"

    get "/api/bridge/tasks/next", params: { id: personal.tasks.first.id }, headers: mate_auth
    assert_response :conflict

    get "/api/bridge/tasks/next", headers: mate_auth
    assert_equal shared.tasks.first.id, JSON.parse(response.body)["task_id"],
                 "a teammate's daemon pools on the team-visible run"

    get "/api/bridge/tasks/next", headers: auth
    assert_equal personal.tasks.first.id, JSON.parse(response.body)["task_id"],
                 "the launcher still claims their personal run"
  end

  test "claim with another team's task id returns 409, not the task" do
    run = dispatch_run
    stranger = User.create!(email: "w-#{SecureRandom.hex(4)}@example.com", password: "password123")
    get "/api/bridge/tasks/next", params: { id: run.tasks.first.id },
        headers: { "Authorization" => "Bearer #{stranger.generate_bridge_token!}" }
    assert_response :conflict
    assert_nil run.tasks.first.reload.claimed_by
  end

  test "unauthorized without a valid token" do
    get "/api/bridge/tasks/next", headers: { "Authorization" => "Bearer nope" }
    assert_response :unauthorized
    get "/api/bridge/tasks/next"
    assert_response :unauthorized
  end

  test "a regenerated token revokes the old one" do
    old = @token
    @user.generate_bridge_token!
    get "/api/bridge/tasks/next", headers: { "Authorization" => "Bearer #{old}" }
    assert_response :unauthorized
  end

  test "result completes the step and advances the run" do
    run = dispatch_run
    get "/api/bridge/tasks/next", headers: auth
    task_id = JSON.parse(response.body)["task_id"]

    post "/api/bridge/tasks/#{task_id}/result",
         params: { status: "completed", summary: "done", agent: "claude",
                   model: "anthropic/claude-opus-4-8",
                   artifacts: [ { type: "pr", url: "http://x/1" } ] },
         headers: auth
    assert_response :ok
    task = run.tasks.first.reload
    assert task.completed?
    assert_equal "done", task.result["summary"]
    assert_equal "claude", task.result_agent
    assert_equal "anthropic/claude-opus-4-8", task.result_model
    assert run.reload.running?   # single step → completion runs via the enqueued advance
  end

  test "a token from outside the team cannot post to its tasks" do
    run = dispatch_run
    task = Task.claim_next_for(@user)
    stranger = User.create!(email: "y-#{SecureRandom.hex(4)}@example.com", password: "password123")

    post "/api/bridge/tasks/#{task.id}/result",
         params: { status: "completed" },
         headers: { "Authorization" => "Bearer #{stranger.generate_bridge_token!}" }
    assert_response :not_found
    assert task.reload.running?
  end

  test "events appends a progress entry" do
    dispatch_run
    task = Task.claim_next_for(@user)
    post "/api/bridge/tasks/#{task.id}/events",
         params: { kind: "log", text: "running tests" }, headers: auth
    assert_response :accepted
    assert_equal "running tests", task.reload.progress.last["text"]
  end

  test "claim and progress broadcast the run page live" do
    run = dispatch_run
    assert_turbo_stream_broadcasts(run.conversation) do
      get "/api/bridge/tasks/next", headers: auth.merge("X-Bridge-Client" => "apollo")
    end

    task = run.tasks.first
    assert_turbo_stream_broadcasts(run.conversation) do
      post "/api/bridge/tasks/#{task.id}/events",
           params: { kind: "log", text: "working — running tests" }, headers: auth
    end
  end

  test "claim and events stamp the liveness heartbeat" do
    run = dispatch_run
    task = run.tasks.first
    assert_nil task.last_reported_at

    get "/api/bridge/tasks/next", headers: auth
    claimed_at = task.reload.last_reported_at
    assert claimed_at.present?

    travel 5.minutes do
      post "/api/bridge/tasks/#{task.id}/events",
           params: { kind: "log", text: "still here" }, headers: auth
      assert_operator task.reload.last_reported_at, :>, claimed_at
    end
  end

  test "claim scoped to a project skips other projects' tasks" do
    other = dispatch_run                       # older, in the helper's project
    project = @team.projects.create!(name: "metis-api")
    run = WorkflowRun.start(team: @team, user: @user, steps: [ LOCAL_STEP ], project: project)
    WorkflowAdvanceJob.perform_now(run.id)

    get "/api/bridge/tasks/next", params: { project: "Metis-API" }, headers: auth
    assert_response :success
    assert_equal run.tasks.first.id, JSON.parse(response.body)["task_id"]
    assert_nil other.tasks.first.reload.claimed_by_user_id

    get "/api/bridge/tasks/next", params: { project: "no-such-project" }, headers: auth
    assert_response :no_content
  end

  test "a cancelled run 410s the next progress post and result" do
    run = dispatch_run
    task = Task.claim_next_for(@user)
    run.reject_current_gate!(by: @user)

    post "/api/bridge/tasks/#{task.id}/events",
         params: { kind: "log", text: "tests green" }, headers: auth
    assert_response :gone

    post "/api/bridge/tasks/#{task.id}/result",
         params: { status: "completed", summary: "done" }, headers: auth
    assert_response :gone
    assert task.reload.rejected?
    assert_empty task.result
  end

  test "show reports status and claim holder for cancellation polling" do
    run = dispatch_run
    task = Task.claim_next_for(@user, client: "mikes-mbp")

    get "/api/bridge/tasks/#{task.ref}", headers: auth
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "running", body["status"]
    assert_equal "mikes-mbp", body["claimed_by"]

    task.reclaim!
    run.reject_current_gate!(by: @user)
    get "/api/bridge/tasks/#{task.id}", headers: auth
    body = JSON.parse(response.body)
    assert_equal "rejected", body["status"]
    assert_nil body["claimed_by"]
  end

  test "show is scoped to the user's teams" do
    run = dispatch_run
    stranger = User.create!(email: "x-#{SecureRandom.hex(4)}@example.com", password: "password123")
    get "/api/bridge/tasks/#{run.tasks.first.id}",
        headers: { "Authorization" => "Bearer #{stranger.generate_bridge_token!}" }
    assert_response :not_found
  end

  test "a result after reclaim is discarded with 410" do
    run = dispatch_run
    task = Task.claim_next_for(@user)
    task.reclaim!

    post "/api/bridge/tasks/#{task.id}/result",
         params: { status: "completed", summary: "too late" }, headers: auth
    assert_response :gone
    task.reload
    assert task.running?, "the task stays claimable"
    assert_empty task.result
    assert run.reload.awaiting_local?
  end
end
