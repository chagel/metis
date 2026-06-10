require "test_helper"

class Api::Bridge::TasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "abt-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @token = @user.generate_bridge_token!
  end

  def auth = { "Authorization" => "Bearer #{@token}" }

  LOCAL = { "name" => "impl", "prompt" => "implement", "run" => "local" }.freeze

  def dispatch_run(steps = [ LOCAL ])
    run = WorkflowRun.start(team: @team, user: @user, steps: steps)
    WorkflowAdvanceJob.perform_now(run.id)   # dispatch the delegated step
    run.reload
  end

  test "claim returns the dispatched task, stamps presence and client name" do
    run = dispatch_run
    get "/api/bridge/tasks/next", headers: auth.merge("X-Bridge-Client" => "mikes-mbp")
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal run.tasks.first.id, body["task_id"]
    assert_equal "implement", body["prompt"]
    assert_equal "mikes-mbp", run.tasks.first.reload.claimed_by
    assert @user.reload.bridge_seen_at.present?
  end

  test "claim returns 204 when nothing is dispatched" do
    get "/api/bridge/tasks/next", headers: auth
    assert_response :no_content
  end

  test "claim payload carries prior steps' full content and artifact urls" do
    run = WorkflowRun.start(team: @team, user: @user, steps: [
      { "name" => "spec", "prompt" => "write the spec" }, LOCAL
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

  test "index lists the claim queue without claiming" do
    workflow = @team.workflows.create!(name: "Ship it", steps: [ LOCAL ])
    run = WorkflowRun.start(team: @team, user: @user, workflow: workflow)
    WorkflowAdvanceJob.perform_now(run.id)

    get "/api/bridge/tasks", headers: auth
    assert_response :success
    tasks = JSON.parse(response.body)["tasks"]
    assert_equal [ run.tasks.first.id ], tasks.map { |t| t["task_id"] }
    assert_equal "impl", tasks.first["name"]
    assert_equal "Ship it", tasks.first["workflow"]
    assert_nil run.tasks.first.reload.claimed_by, "listing must not claim"
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

  test "claim with an unavailable id returns 409" do
    run = dispatch_run
    Task.claim_next_for(@user)   # someone else got there first
    get "/api/bridge/tasks/next", params: { id: run.tasks.first.id }, headers: auth
    assert_response :conflict
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
         params: { status: "completed", summary: "done", artifacts: [ { type: "pr", url: "http://x/1" } ] },
         headers: auth
    assert_response :ok
    task = run.tasks.first.reload
    assert task.completed?
    assert_equal "done", task.result["summary"]
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
end
