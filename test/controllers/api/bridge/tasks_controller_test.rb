require "test_helper"

class Api::Bridge::TasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "abt-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @device = @team.devices.create!(user: @user, name: "macbook")
    @token = @device.plaintext_token
  end

  def auth = { "Authorization" => "Bearer #{@token}" }

  LOCAL = { "name" => "impl", "prompt" => "implement", "run" => "local" }.freeze

  def dispatch_run(steps = [ LOCAL ])
    run = WorkflowRun.start(team: @team, user: @user, steps: steps)
    WorkflowAdvanceJob.perform_now(run.id)   # dispatch the delegated step
    run.reload
  end

  test "claim returns the dispatched task and stamps presence" do
    run = dispatch_run
    get "/api/bridge/tasks/next", headers: auth
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal run.tasks.first.id, body["task_id"]
    assert_equal "implement", body["prompt"]
    assert @device.reload.online?
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

  test "a device cannot post to a task it didn't claim" do
    run = dispatch_run
    task = Task.claim_next_for(@device)
    stranger = User.create!(email: "y-#{SecureRandom.hex(4)}@example.com", password: "password123")
    other = stranger.personal_team.devices.create!(user: stranger, name: "theirs")

    post "/api/bridge/tasks/#{task.id}/result",
         params: { status: "completed" },
         headers: { "Authorization" => "Bearer #{other.plaintext_token}" }
    assert_response :not_found
    assert task.reload.running?
  end

  test "events appends a progress entry" do
    dispatch_run
    task = Task.claim_next_for(@device)
    post "/api/bridge/tasks/#{task.id}/events",
         params: { kind: "log", text: "running tests" }, headers: auth
    assert_response :accepted
    assert_equal "running tests", task.reload.progress.last["text"]
  end
end
