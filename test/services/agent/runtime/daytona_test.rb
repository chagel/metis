require "test_helper"

class Agent::Runtime::DaytonaTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  BAKED = Agent::Runtime::Daytona::BAKED_REPO_SKILLS_DIR
  WORKSPACE = Agent::Runtime::Daytona::WORKSPACE_DIR

  setup do
    @user = User.create!(email: "daytona@example.com", password: "password123")
    @conversation = @user.conversations.create!
    @runtime = Agent::Runtime::Daytona.new(conversation: @conversation)
  end

  class FakeFs
    attr_reader :writes
    attr_accessor :exist_paths, :entries_by_dir, :read_responses

    def initialize
      @writes = {}
      @exist_paths = []
      @entries_by_dir = {}
      @read_responses = {}
    end

    def write_file(path, content, **)
      @writes[path] = content
    end

    def download_file(path, *)
      @read_responses.fetch(path)
    end

    def list_files(path)
      @entries_by_dir.fetch(path, [])
    end

    def get_file_info(path)
      raise ::Daytona::NotFoundError, "missing" unless @exist_paths.include?(path)

      { "name" => File.basename(path) }
    end
  end

  class FakeProcess
    attr_reader :runs

    def initialize
      @runs = []
    end

    def exec(command, **)
      @runs << command
      nil
    end
  end

  # Fake Daytona sandbox tracking start / stop / delete.
  class FakeSandbox
    attr_reader :id, :fs, :process, :stop_count, :start_timeouts, :stop_timeouts
    attr_accessor :state

    def initialize(id: "sbx-fake", state: "started", baked: true, on_stop: nil, stop_error: nil)
      @id = id
      @state = state
      @on_stop = on_stop
      @stop_error = stop_error
      @fs = FakeFs.new
      @process = FakeProcess.new
      @start_timeouts = []
      @stop_timeouts = []
      @stop_count = 0
      @deleted = false
      @fs.exist_paths << BAKED if baked
    end

    def start(timeout: nil)
      @start_timeouts << timeout
      @state = "started"
    end

    def stop(timeout: nil)
      @on_stop&.call(self)
      raise @stop_error if @stop_error

      @stop_timeouts << timeout
      @stop_count += 1
      @state = "stopped"
    end

    def delete(timeout: nil)
      @deleted = true
    end

    def deleted?
      @deleted
    end
  end

  class FakeClient
    attr_reader :created_params, :got_ids

    def initialize(create: nil, get: nil, get_error: nil)
      @create = create
      @get = get
      @get_error = get_error
      @created_params = []
      @got_ids = []
    end

    def create(params, timeout: nil)
      @created_params << params
      @create
    end

    def get(id)
      @got_ids << id
      raise @get_error if @get_error

      @get
    end
  end

  def fake_session
    session = Object.new
    def session.close = nil
    session
  end

  def file_entry(name, dir: false, size: nil, mtime: nil)
    { "name" => name, "isDir" => dir, "size" => size, "modTime" => mtime&.iso8601 }
  end

  # Stub Agent::Runtime::Daytona.client and PiAgent.session for the block.
  def with_daytona(client:, session: fake_session)
    client_original = Agent::Runtime::Daytona.method(:client)
    session_original = PiAgent.method(:session)
    Agent::Runtime::Daytona.define_singleton_method(:client) { client }
    PiAgent.define_singleton_method(:session) { |*, **| session }
    yield
  ensure
    Agent::Runtime::Daytona.define_singleton_method(:client, client_original)
    PiAgent.define_singleton_method(:session, session_original)
  end

  # Point Agent::Workspace::SKILLS_SOURCE at a tmp dir for the block.
  def with_skills_source
    Dir.mktmpdir do |tmp|
      source = Pathname.new(tmp).join("skills")
      FileUtils.mkdir_p(source)
      original = Agent::Workspace::SKILLS_SOURCE
      Agent::Workspace.send(:remove_const, :SKILLS_SOURCE)
      Agent::Workspace.const_set(:SKILLS_SOURCE, source)
      Agent::Workspace.reset_repo_skills_fingerprint!
      begin
        yield source
      ensure
        Agent::Workspace.send(:remove_const, :SKILLS_SOURCE)
        Agent::Workspace.const_set(:SKILLS_SOURCE, original)
        Agent::Workspace.reset_repo_skills_fingerprint!
      end
    end
  end

  test "session_dir is the in-sandbox session path" do
    assert_equal Agent::Runtime::Daytona::SESSION_DIR, @runtime.session_dir.to_s
  end

  test "initial_status predicts creating without a stored sandbox, resuming with one" do
    assert_equal "Creating sandbox", @runtime.initial_status

    @conversation.update_column(:daytona_sandbox_id, "sbx-warm")
    assert_equal "Resuming sandbox", Agent::Runtime::Daytona.new(conversation: @conversation).initial_status
  end

  test "first turn creates a sandbox, schedules its stop, and records the id on the conversation" do
    sandbox = FakeSandbox.new(id: "sbx-new")
    client = FakeClient.new(create: sandbox)

    assert_enqueued_with(job: DaytonaStopJob, args: [ @conversation.id, "sbx-new", nil ]) do
      with_daytona(client: client) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
      end
    end

    assert_equal 0, sandbox.stop_count, "stop is deferred to the keep-warm job, not inline"
    refute sandbox.deleted?, "sandbox not deleted — the next turn will resume it"
    assert_equal "sbx-new", @conversation.reload.daytona_sandbox_id
  end

  test "create passes the native idle-lifecycle intervals from config" do
    sandbox = FakeSandbox.new(id: "sbx-new")
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    params = client.created_params.first
    assert_equal Rails.application.config.x.agent.daytona_snapshot, params.snapshot
    assert_equal Rails.application.config.x.agent.daytona_auto_stop_minutes, params.auto_stop_interval
    assert_equal Rails.application.config.x.agent.daytona_auto_archive_minutes, params.auto_archive_interval
    assert_equal Rails.application.config.x.agent.daytona_auto_delete_minutes, params.auto_delete_interval
  end

  test "discards .mcp.json at end of turn so the fs holds no bearer tokens" do
    mcp_path = "#{WORKSPACE}/#{Agent::McpConfig::FILENAME}"
    sandbox = FakeSandbox.new(id: "sbx-new")
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_includes sandbox.process.runs, "rm -f #{mcp_path}",
                    "mcp config deleted at end of turn — the warm/persisted fs must hold no tokens"
  end

  test "subsequent turns resume the stored sandbox and start it when stopped" do
    @conversation.update_column(:daytona_sandbox_id, "sbx-existing")
    sandbox = FakeSandbox.new(id: "sbx-existing", state: "stopped")
    client = FakeClient.new(get: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal [ "sbx-existing" ], client.got_ids
    assert_equal [ Agent::Runtime::Daytona::SANDBOX_TIMEOUT ], sandbox.start_timeouts,
                 "started with the runtime's timeout"
    assert_equal 0, sandbox.stop_count, "stop deferred to the keep-warm job"
    assert_equal "sbx-existing", @conversation.reload.daytona_sandbox_id, "id unchanged when reused"
  end

  test "an already-started resumed sandbox is not started again" do
    @conversation.update_column(:daytona_sandbox_id, "sbx-warm")
    sandbox = FakeSandbox.new(id: "sbx-warm", state: "started")
    client = FakeClient.new(get: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_empty sandbox.start_timeouts, "no redundant start when already running"
  end

  test "a missing stored sandbox falls back to fresh provision and clears the stale id" do
    @conversation.update_column(:daytona_sandbox_id, "sbx-gone")
    fresh = FakeSandbox.new(id: "sbx-replacement")
    client = FakeClient.new(create: fresh, get_error: ::Daytona::NotFoundError.new("no such sandbox"))

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal "sbx-replacement", @conversation.reload.daytona_sandbox_id,
                 "the new sandbox's id replaces the stale one"
  end

  test "stop_sandbox stops the box for the deferred keep-warm stop" do
    sandbox = FakeSandbox.new(id: "sbx-stop")
    client = FakeClient.new(get: sandbox)

    with_daytona(client: client) do
      Agent::Runtime::Daytona.stop_sandbox(@conversation, "sbx-stop")
    end

    assert_equal 1, sandbox.stop_count
    refute sandbox.deleted?
  end

  test "stop_sandbox best-effort deletes the sandbox and clears the id when stop fails" do
    @conversation.update_column(:daytona_sandbox_id, "sbx-stop-fail")
    sandbox = FakeSandbox.new(id: "sbx-stop-fail", stop_error: ::Daytona::DaytonaError.new("stop http 500"))
    client = FakeClient.new(get: sandbox)

    with_daytona(client: client) do
      Agent::Runtime::Daytona.stop_sandbox(@conversation, "sbx-stop-fail")
    end

    assert sandbox.deleted?, "fallback to delete when stop fails"
    assert_nil @conversation.reload.daytona_sandbox_id, "stale id cleared"
  end

  test "uploads the app's pi extensions into the sandbox each turn" do
    sandbox = FakeSandbox.new
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    staged = sandbox.fs.writes.keys.grep(%r{\A#{Agent::Runtime::Daytona::EXTENSIONS_DIR}/})
    assert staged.any? { |path| path.end_with?("/web-tools.ts") },
           "web-tools extension uploaded into the sandbox"
  end

  test "extension_paths point at the uploaded extensions inside the sandbox" do
    paths = @runtime.extension_paths.map(&:to_s)

    assert_includes paths, "#{Agent::Runtime::Daytona::EXTENSIONS_DIR}/web-tools.ts"
  end

  test "drains the .pi/skills/.imports sentinel into ImportSkillJob enqueues" do
    sandbox = FakeSandbox.new
    imports_path = "#{WORKSPACE}/.pi/skills/.imports"
    sandbox.fs.exist_paths << imports_path
    sandbox.fs.read_responses[imports_path] = <<~TXT
      anthropics/skills/skills/pdf
      # comment
      anthropics/skills/skills/xlsx
    TXT
    client = FakeClient.new(create: sandbox)

    assert_enqueued_jobs 2, only: ImportSkillJob do
      with_daytona(client: client) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
      end
    end
  end

  test "uploads the team's enabled skills into the sandbox skills tree" do
    skill = @conversation.team.skills.create!(slug: "summarize", description: "x")
    skill.replace_skill_md!("# body")
    skill.save!
    sandbox = FakeSandbox.new
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    staged = "#{WORKSPACE}/.pi/skills/summarize/SKILL.md"
    assert_equal "# body", sandbox.fs.writes[staged]
  end

  test "fresh sandbox with a baked snapshot copies repo skills with one sandbox-local cp" do
    sandbox = FakeSandbox.new(baked: true)
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    repo_uploads = sandbox.fs.writes.keys.grep(%r{\A#{WORKSPACE}/\.pi/skills/[^/]+/SKILL\.md\z})
    assert_empty repo_uploads, "baked snapshot path must not upload repo files"

    cp_calls = sandbox.process.runs.select { |c| c.include?("cp -r") && c.include?(BAKED) }
    assert cp_calls.any?, "expected a cp -r from the baked dir"
  end

  test "fresh sandbox without a baked snapshot uploads the repo .pi/skills/ tree from the host" do
    sandbox = FakeSandbox.new(baked: false)
    client = FakeClient.new(create: sandbox)

    with_skills_source do |source|
      FileUtils.mkdir_p(source.join("summarize"))
      File.write(source.join("summarize/SKILL.md"), "# repo skill")
      with_daytona(client: client) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
      end
    end

    # The host fallback tars the tree, uploads one archive, and extracts it
    # in the sandbox — one upload instead of ~300 per-file writes.
    assert sandbox.fs.writes.key?("/tmp/metis-repo-skills.tgz"), "uploads the skills tarball"
    extracted = sandbox.process.runs.any? { |c| c.include?("tar -xzf") && c.include?("#{WORKSPACE}/.pi/skills") }
    assert extracted, "extracts the tarball into the workspace skills dir"
  end

  test "resumed sandbox skips team-skill rewrite when the signature marker matches the DB" do
    @conversation.update_column(:daytona_sandbox_id, "sbx-warm")
    skill = @conversation.team.skills.create!(slug: "tldr", description: "x")
    skill.replace_skill_md!("# body")
    skill.save!
    signature = Skill.team_signature(@conversation.team)

    dest_root = "#{WORKSPACE}/.pi/skills"
    marker_path = "#{dest_root}/#{Agent::Runtime::Daytona::TEAM_SKILLS_MARKER}"
    sandbox = FakeSandbox.new(id: "sbx-warm", state: "started")
    sandbox.fs.exist_paths << marker_path
    sandbox.fs.read_responses[marker_path] = signature
    client = FakeClient.new(get: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    refute sandbox.fs.writes.key?("#{dest_root}/tldr/SKILL.md"),
           "matching signature must skip the full team-skill rewrite"
  end

  test "resumed sandbox restages team skills when the signature drifts" do
    @conversation.update_column(:daytona_sandbox_id, "sbx-warm")
    skill = @conversation.team.skills.create!(slug: "tldr", description: "x")
    skill.replace_skill_md!("# body")
    skill.save!

    dest_root = "#{WORKSPACE}/.pi/skills"
    marker_path = "#{dest_root}/#{Agent::Runtime::Daytona::TEAM_SKILLS_MARKER}"
    sandbox = FakeSandbox.new(id: "sbx-warm", state: "started")
    sandbox.fs.exist_paths << marker_path
    sandbox.fs.read_responses[marker_path] = "stale-signature"
    client = FakeClient.new(get: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal "# body", sandbox.fs.writes["#{dest_root}/tldr/SKILL.md"],
                 "stale signature triggers a full restage"
    assert sandbox.fs.writes.key?(marker_path), "marker rewritten after the restage"
  end

  test "resumed sandbox removes stale team-skill dirs no longer enabled" do
    @conversation.update_column(:daytona_sandbox_id, "sbx-warm")
    dest_root = "#{WORKSPACE}/.pi/skills"
    sandbox = FakeSandbox.new(id: "sbx-warm", state: "started")
    sandbox.fs.exist_paths << dest_root
    sandbox.fs.entries_by_dir[dest_root] = [ file_entry("orphaned", dir: true) ]
    client = FakeClient.new(get: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    rm_calls = sandbox.process.runs.select { |c| c.include?("rm -rf") && c.include?("orphaned") }
    assert rm_calls.any?, "orphan team-skill dir gets cleaned up on resume"
  end

  test "ingests touched team skills from the sandbox at turn end" do
    sandbox = FakeSandbox.new
    skill_dir = "#{WORKSPACE}/.pi/skills/code-review"
    skill_md_path = "#{skill_dir}/SKILL.md"
    sandbox.fs.exist_paths << skill_dir
    sandbox.fs.entries_by_dir[skill_dir] = [ file_entry("SKILL.md", size: 10) ]
    sandbox.fs.read_responses[skill_md_path] = <<~MD
      ---
      name: code-review
      description: From the sandbox.
      ---
      # body
    MD
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        @runtime.note_skill_touched("code-review")
      end
    end

    skill = @conversation.team.skills.find_by(slug: "code-review")
    assert_not_nil skill, "touched slug was read from the sandbox + ingested"
    assert_equal "From the sandbox.", skill.description
  end

  test "does not ingest sandbox files for slugs the adapter did not record" do
    sandbox = FakeSandbox.new
    skill_dir = "#{WORKSPACE}/.pi/skills/decoy"
    sandbox.fs.exist_paths << skill_dir
    sandbox.fs.entries_by_dir[skill_dir] = [ file_entry("SKILL.md", size: 5) ]
    sandbox.fs.read_responses["#{skill_dir}/SKILL.md"] = "# never"
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_nil @conversation.team.skills.find_by(slug: "decoy")
  end

  test "projects the conversation's uploaded files into the sandbox uploads dir" do
    sandbox = FakeSandbox.new
    message = @conversation.messages.create!(role: :user, content: "hi", streaming_status: :done)
    message.files.attach(io: StringIO.new("file contents"), filename: "notes.txt", content_type: "text/plain")
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    staged = "#{WORKSPACE}/uploads/notes.txt"
    assert_equal "file contents", sandbox.fs.writes[staged]
  end

  test "runtime_info reports the runtime name and the sandbox id" do
    sandbox = FakeSandbox.new(id: "sbx-99")
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal({ "runtime" => "daytona", "sandbox_id" => "sbx-99" }, @runtime.runtime_info)
  end

  test "collects artifacts from the sandbox during the turn" do
    art_path = "#{Agent::Runtime::Daytona::ARTIFACTS_DIR}/report.csv"
    sandbox = FakeSandbox.new
    sandbox.fs.exist_paths << Agent::Runtime::Daytona::ARTIFACTS_DIR
    sandbox.fs.entries_by_dir[Agent::Runtime::Daytona::ARTIFACTS_DIR] = [
      file_entry("report.csv", size: 8, mtime: Time.now + 5)
    ]
    sandbox.fs.read_responses[art_path] = "a,b\n1,2\n"
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal [ "report.csv" ], @runtime.artifacts.map { |a| a[:filename] },
                 "artifacts collected while the sandbox is reachable"
    assert_equal "a,b\n1,2\n", @runtime.artifacts.first[:io].read
  end

  test "skips artifacts whose modified time predates the turn" do
    art_path = "#{Agent::Runtime::Daytona::ARTIFACTS_DIR}/old.csv"
    sandbox = FakeSandbox.new
    sandbox.fs.exist_paths << Agent::Runtime::Daytona::ARTIFACTS_DIR
    sandbox.fs.entries_by_dir[Agent::Runtime::Daytona::ARTIFACTS_DIR] = [
      file_entry("old.csv", size: 5, mtime: Time.now - 3600)
    ]
    sandbox.fs.read_responses[art_path] = "stale"
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_empty @runtime.artifacts
  end

  test "skips artifacts above the size cap" do
    big_path = "#{Agent::Runtime::Daytona::ARTIFACTS_DIR}/huge.bin"
    ok_path = "#{Agent::Runtime::Daytona::ARTIFACTS_DIR}/ok.csv"
    sandbox = FakeSandbox.new
    sandbox.fs.exist_paths << Agent::Runtime::Daytona::ARTIFACTS_DIR
    sandbox.fs.entries_by_dir[Agent::Runtime::Daytona::ARTIFACTS_DIR] = [
      file_entry("huge.bin", size: 11.megabytes, mtime: Time.now + 5),
      file_entry("ok.csv", size: 12, mtime: Time.now + 5)
    ]
    sandbox.fs.read_responses[ok_path] = "a,b\n1,2\n"
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal [ "ok.csv" ], @runtime.artifacts.map { |a| a[:filename] }
  end

  test "preserves the subdirectory in the artifact filename" do
    art_path = "#{Agent::Runtime::Daytona::ARTIFACTS_DIR}/reports/q4.csv"
    sandbox = FakeSandbox.new
    sandbox.fs.exist_paths << Agent::Runtime::Daytona::ARTIFACTS_DIR
    sandbox.fs.entries_by_dir[Agent::Runtime::Daytona::ARTIFACTS_DIR] = [
      file_entry("reports", dir: true, mtime: Time.now + 5)
    ]
    sandbox.fs.entries_by_dir["#{Agent::Runtime::Daytona::ARTIFACTS_DIR}/reports"] = [
      file_entry("q4.csv", size: 8, mtime: Time.now + 5)
    ]
    sandbox.fs.read_responses[art_path] = "csv data"
    client = FakeClient.new(create: sandbox)

    with_daytona(client: client) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal [ "reports/q4.csv" ], @runtime.artifacts.map { |a| a[:filename] }
  end

  test ".kill_sandbox swallows NotFoundError so cleanup is idempotent" do
    client = FakeClient.new(get_error: ::Daytona::NotFoundError.new("already gone"))
    with_daytona(client: client) do
      assert_nothing_raised { Agent::Runtime::Daytona.kill_sandbox("sbx-doesnt-exist") }
    end
  end

  test ".kill_sandbox is a no-op when the id is blank" do
    client = FakeClient.new(get: FakeSandbox.new)
    with_daytona(client: client) do
      Agent::Runtime::Daytona.kill_sandbox(nil)
      Agent::Runtime::Daytona.kill_sandbox("")
    end
    assert_empty client.got_ids, "no client call for a blank id"
  end
end
