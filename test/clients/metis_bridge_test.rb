require "test_helper"

load File.expand_path("../../clients/metis-bridge/metis-bridge", __dir__)

# The daemon is a single stdlib-only file, loaded here and tested against
# stub transports, a fake agent subprocess, and real temp git repos.
class MetisBridgeTest < ActiveSupport::TestCase
  class StubApi
    attr_reader :events, :results

    def initialize(task_state: { "status" => "running", "claimed_by" => "testbox" }, gone_on_event: false)
      @task_state = task_state
      @gone_on_event = gone_on_event
      @events = []
      @results = []
    end

    def event(_id, text)
      raise MetisBridge::Api::Gone, "gone" if @gone_on_event

      @events << text
    end

    def result(_id, status:, summary:, artifacts: [])
      @results << { status: status, summary: summary, artifacts: artifacts }
    end

    def task(_id)
      @task_state
    end
  end

  class FakeAgent
    def initialize(script)
      @script = script
    end

    def command(_prompt, _extra_args)
      [ RbConfig.ruby, "-e", %(require "json"; $stdout.sync = true; #{@script}) ]
    end

    def parse(line)
      event = JSON.parse(line)
      { text: event["text"], final: event["final"] }.compact
    rescue JSON::ParserError
      {}
    end
  end

  def config(repo, root, overrides = {})
    MetisBridge::Config.new({
      "server" => "http://metis.test", "token" => "mbt_x", "client" => "testbox",
      "projects" => { "proj" => repo }, "workspaces_root" => root,
      "heartbeat_interval" => 1000, "cancel_poll_interval" => 1000, "inactivity_timeout" => 30
    }.merge(overrides))
  end

  def task_payload
    { "task_id" => 1, "ref" => "RUN-1", "prompt" => "implement the thing",
      "context" => { "project" => { "name" => "proj" },
                     "prior_steps" => [ { "name" => "spec", "content" => "the spec",
                                          "artifacts" => [ { "url" => "http://a/spec.md" } ] } ] } }
  end

  def with_repo
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      root = File.join(dir, "worktrees")
      FileUtils.mkdir_p(repo)
      system("git", "-C", repo, "init", "-q", exception: true)
      system("git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t",
             "commit", "-q", "--allow-empty", "-m", "init", exception: true)
      yield repo, root
    end
  end

  def run_worker(repo, root, script, api: StubApi.new, overrides: {}, ref: "RUN-1")
    cfg = config(repo, root, overrides)
    worker = MetisBridge::TaskWorker.new(api: api, config: cfg, task: task_payload.merge("ref" => ref),
                                         logger: Logger.new(IO::NULL))
    worker.instance_variable_set(:@agent, FakeAgent.new(script))
    worker.run
    api
  end

  test "happy path: worktree, agent run, structured result submitted" do
    with_repo do |repo, root|
      api = run_worker(repo, root, <<~SCRIPT)
        puts({ text: "editing files" }.to_json)
        final = "All done\\nMETIS_RESULT: {\\"status\\":\\"completed\\",\\"summary\\":\\"capped retries\\",\\"artifacts\\":[{\\"type\\":\\"pr\\",\\"url\\":\\"http://x/1\\"}]}"
        puts({ final: final }.to_json)
      SCRIPT

      result = api.results.last
      assert_equal "completed", result[:status]
      assert_equal "capped retries", result[:summary]
      assert_equal [ { "type" => "pr", "url" => "http://x/1" } ], result[:artifacts]

      worktree = File.join(root, "RUN-1")
      assert File.directory?(worktree)
      branch = `git -C #{worktree} branch --show-current`.strip
      assert_equal "metis/run-1", branch
      meta = JSON.parse(File.read(File.join(worktree, ".metis-bridge.json")))
      assert_equal "completed", meta["status"]
      assert meta["settled_at"].present?
    end
  end

  test "falls back to the agent's final message when no structured result" do
    with_repo do |repo, root|
      api = run_worker(repo, root, %(puts({ final: "Shipped the fix." }.to_json)))
      assert_equal "completed", api.results.last[:status]
      assert_equal "Shipped the fix.", api.results.last[:summary]
    end
  end

  test "non-zero agent exit reports a failed result" do
    with_repo do |repo, root|
      api = run_worker(repo, root, %(puts({ text: "boom" }.to_json); exit 1))
      assert_equal "failed", api.results.last[:status]
      assert_match(/exited non-zero/i, api.results.last[:summary])
    end
  end

  test "watchdog kills a silent agent and reports failed" do
    with_repo do |repo, root|
      api = run_worker(repo, root, "sleep 30", overrides: { "inactivity_timeout" => 1 })
      assert_equal "failed", api.results.last[:status]
      assert_match(/watchdog/i, api.results.last[:summary])
    end
  end

  test "cancellation poll kills the agent when the task settles or the claim moves" do
    with_repo do |repo, root|
      api = StubApi.new(task_state: { "status" => "rejected", "claimed_by" => nil })
      run_worker(repo, root, %(puts({ text: "start" }.to_json); sleep 30),
                 api: api, overrides: { "cancel_poll_interval" => 1 })
      assert_equal "failed", api.results.last[:status]
      assert_match(/settled or claim moved/, api.results.last[:summary])
    end
  end

  test "heartbeats post progress and a 410 on heartbeat stops everything" do
    with_repo do |repo, root|
      api = StubApi.new
      run_worker(repo, root, %(puts({ text: "milestone" }.to_json); sleep 3; puts({ final: "done" }.to_json)),
                 api: api, overrides: { "heartbeat_interval" => 1 })
      assert api.events.any? { |e| e.include?("working — milestone") }

      gone = StubApi.new(gone_on_event: true)
      run_worker(repo, root, %(puts({ text: "x" }.to_json); sleep 30),
                 api: gone, overrides: { "heartbeat_interval" => 1 }, ref: "RUN-2")
      assert_empty gone.results, "no result reported once the task is gone"
    end
  end

  test "missing checkout for the task's project fails fast without a worktree" do
    with_repo do |repo, root|
      api = StubApi.new
      cfg = config(repo, root)
      task = task_payload.merge("context" => { "project" => { "name" => "other-proj" } })
      MetisBridge::TaskWorker.new(api: api, config: cfg, task: task, logger: Logger.new(IO::NULL)).run
      assert_equal "failed", api.results.last[:status]
      assert_match(/No checkout configured/, api.results.last[:summary])
      assert_not File.directory?(File.join(root, "RUN-1"))
    end
  end

  test "re-claim reuses the existing worktree and branch" do
    with_repo do |repo, root|
      run_worker(repo, root, %(File.write("partial.txt", "wip"); puts({ final: "part one" }.to_json)))
      assert File.exist?(File.join(root, "RUN-1", "partial.txt"))

      api = run_worker(repo, root, <<~SCRIPT)
        raise "partial work lost" unless File.exist?("partial.txt")
        puts({ final: "resumed" }.to_json)
      SCRIPT
      assert_equal "completed", api.results.last[:status]
      assert_equal "resumed", api.results.last[:summary]
    end
  end

  test "prompt folds in prior steps, artifacts, and the unattended rules" do
    with_repo do |repo, root|
      worker = MetisBridge::TaskWorker.new(api: StubApi.new, config: config(repo, root),
                                           task: task_payload, logger: Logger.new(IO::NULL))
      prompt = worker.send(:prompt)
      assert_includes prompt, "implement the thing"
      assert_includes prompt, "earlier step: spec"
      assert_includes prompt, "the spec"
      assert_includes prompt, "http://a/spec.md"
      assert_includes prompt, "METIS_RESULT:"
      assert_includes prompt, "metis/run-1"
    end
  end

  test "agent arg hygiene strips protocol-breaking flags" do
    filtered = MetisBridge::Agents.filter(
      %w[--model opus --output-format text --resume abc --allowedTools Bash --mode=json],
      MetisBridge::Agents::Claude::BLOCKED + [ "--mode" ]
    )
    assert_equal %w[--model opus --allowedTools Bash], filtered
  end

  test "claude adapter builds a stream-json command and parses its events" do
    agent = MetisBridge::Agents::Claude.new
    cmd = agent.command("do it", [ "--model", "opus" ])
    assert_equal %w[claude -p], cmd.first(2)
    assert_includes cmd, "stream-json"
    assert_includes cmd, "--model"

    assert_equal "hi", agent.parse(%({"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}))[:text]
    final = agent.parse(%({"type":"result","result":"all done","is_error":false}))
    assert_equal "all done", final[:final]
    assert_equal({}, agent.parse("not json"))
  end

  test "pi adapter builds a json-mode command and parses assistant message_end" do
    agent = MetisBridge::Agents::Pi.new
    cmd = agent.command("do it", [])
    assert_equal %w[pi -p --mode json], cmd.first(4)
    assert_equal "do it", cmd.last

    line = %({"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}})
    assert_equal "done", agent.parse(line)[:final]
    user_line = %({"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"hi"}]}})
    assert_equal({}, agent.parse(user_line))
  end

  test "codex adapter builds an exec --json command and parses item events" do
    agent = MetisBridge::Agents::Codex.new
    cmd = agent.command("do it", [ "--model", "gpt-5.5" ])
    assert_equal %w[codex exec --json --full-auto --skip-git-repo-check], cmd.first(5)
    assert_equal "do it", cmd.last
    assert_includes cmd, "--model"

    final = agent.parse(%({"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"ready"}}))
    assert_equal "ready", final[:final]
    activity = agent.parse(%({"type":"item.completed","item":{"type":"command_execution","text":"ls"}}))
    assert_equal "ls", activity[:text]
    assert_nil activity[:final]
    assert_equal({}, agent.parse(%({"type":"turn.completed","usage":{}})))
  end

  test "worktree gc removes settled and orphaned dirs, keeps live ones" do
    with_repo do |repo, root|
      run_worker(repo, root, %(puts({ final: "done" }.to_json)))   # settled meta
      live = File.join(root, "RUN-LIVE")
      FileUtils.mkdir_p(live)
      File.write(File.join(live, ".metis-bridge.json"), { "claimed_at" => Time.now.utc.iso8601 }.to_json)
      orphan = File.join(root, "RUN-ORPHAN")
      FileUtils.mkdir_p(orphan)

      MetisBridge::Worktree.gc(root, repo_for: ->(_ref) { repo }, ttl: 60,
                               now: Time.now.utc + 3600)
      assert_not File.directory?(File.join(root, "RUN-1")), "settled past ttl removed"
      assert File.directory?(live), "unsettled task kept"
      assert_not File.directory?(orphan), "orphan past 3x ttl removed"
    end
  end

  test "config validates and expands" do
    error = assert_raises(MetisBridge::Error) { MetisBridge::Config.new({ "server" => "http://x", "token" => "t" }) }
    assert_match(/projects/, error.message)

    cfg = MetisBridge::Config.new(
      "server" => "http://x/", "token" => "t", "projects" => { "p" => "~/code/p" }
    )
    assert_equal "http://x", cfg.server
    assert_equal File.expand_path("~/code/p"), cfg.projects["p"]
    assert_equal 30, cfg.poll_interval
  end
end
