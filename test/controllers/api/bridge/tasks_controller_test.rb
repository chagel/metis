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
