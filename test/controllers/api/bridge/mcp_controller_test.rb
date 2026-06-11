require "test_helper"

class Api::Bridge::McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "mcp-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @token = @user.generate_bridge_token!
  end

  LOCAL = { "name" => "impl", "prompt" => "implement", "run" => "local" }.freeze

  def rpc(method, params = nil, id: 1, token: @token)
    body = { jsonrpc: "2.0", id: id, method: method, params: params }.compact
    post "/api/bridge/mcp", params: body.to_json,
         headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json",
                    "X-Bridge-Client" => "testbox" }
    JSON.parse(response.body) if response.body.present?
  end

  def call_tool(name, args = {})
    rpc("tools/call", { name: name, arguments: args })
  end

  def dispatch_run
    run = WorkflowRun.start(team: @team, user: @user, steps: [ LOCAL ])
    WorkflowAdvanceJob.perform_now(run.id)
    run.reload
  end

  test "initialize negotiates and lists the four tools" do
    body = rpc("initialize", { protocolVersion: "2025-06-18", clientInfo: { name: "cc" } })
    assert_equal "2025-06-18", body.dig("result", "protocolVersion")
    assert_equal "metis-bridge", body.dig("result", "serverInfo", "name")

    body = rpc("tools/list", nil, id: 2)
    assert_equal %w[list_tasks get_next_task report_progress submit_result],
                 body.dig("result", "tools").map { |t| t["name"] }
  end

  test "notifications get 202 and no body" do
    post "/api/bridge/mcp", params: { jsonrpc: "2.0", method: "notifications/initialized" }.to_json,
         headers: { "Authorization" => "Bearer #{@token}", "Content-Type" => "application/json" }
    assert_response :accepted
  end

  test "requires a valid bridge token" do
    post "/api/bridge/mcp", params: { jsonrpc: "2.0", id: 1, method: "ping" }.to_json,
         headers: { "Authorization" => "Bearer nope", "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  test "the full tool lifecycle drives a delegated run to completion" do
    run = dispatch_run
    task_id = run.tasks.first.id

    listed = call_tool("list_tasks")
    assert_includes listed.dig("result", "content", 0, "text"), "\"task_id\": #{task_id}"
    assert_not listed.dig("result", "isError")

    claimed = call_tool("get_next_task", { task_id: task_id })
    assert_includes claimed.dig("result", "content", 0, "text"), "implement"
    assert_equal "testbox", run.tasks.first.reload.claimed_by

    progress = call_tool("report_progress", { task_id: task_id, text: "halfway" })
    assert_not progress.dig("result", "isError")

    done = call_tool("submit_result", { task_id: task_id, status: "completed", summary: "shipped" })
    assert_not done.dig("result", "isError")
    assert run.tasks.first.reload.completed?
    assert_equal "halfway", run.tasks.first.progress.last["text"]
  end

  test "reporting against a dead task tells the agent to stop" do
    run = dispatch_run
    task = Task.claim_next_for(@user, client: "testbox")
    run.reject_current_gate!(by: @user)

    body = call_tool("report_progress", { task_id: task.id, text: "tests green" })
    assert body.dig("result", "isError")
    assert_includes body.dig("result", "content", 0, "text"), "Stop work"

    body = call_tool("submit_result", { task_id: task.id, status: "completed", summary: "done" })
    assert body.dig("result", "isError")
    assert task.reload.rejected?
    assert_empty task.result
  end

  test "claiming an unavailable task id is a tool error, not a crash" do
    run = dispatch_run
    Task.claim_next_for(@user)
    body = call_tool("get_next_task", { task_id: run.tasks.first.id })
    assert body.dig("result", "isError")
    assert_includes body.dig("result", "content", 0, "text"), "no longer claimable"
  end

  test "empty queue and unknown tool degrade gracefully" do
    body = call_tool("get_next_task")
    assert_equal "No delegated tasks waiting.", body.dig("result", "content", 0, "text")

    body = call_tool("nope")
    assert body.dig("result", "isError")

    run = dispatch_run
    body = call_tool("report_progress", { task_id: run.tasks.first.id })   # missing text
    assert body.dig("result", "isError")
    assert_includes body.dig("result", "content", 0, "text"), "Missing argument"

    body = call_tool("report_progress", { task_id: 999_999, text: "hi" })  # not yours
    assert body.dig("result", "isError")
    assert_includes body.dig("result", "content", 0, "text"), "not found"
  end

  test "unknown method returns a JSON-RPC error" do
    body = rpc("resources/list")
    assert_equal(-32_601, body.dig("error", "code"))
  end
end
