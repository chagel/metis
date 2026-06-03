require "test_helper"
require "ostruct"

class Agent::Runtime::E2bTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "e2b@example.com", password: "password123")
    @conversation = @user.conversations.create!
    @runtime = Agent::Runtime::E2b.new(conversation: @conversation)
  end

  class FakeCommands
    attr_reader :runs

    def initialize
      @runs = []
    end

    def run(cmd, **_kwargs)
      @runs << cmd
    end
  end

  class FakeFiles
    attr_reader :writes
    attr_accessor :exist_paths, :entries_by_dir, :read_responses

    def initialize
      @writes = {}
      @exist_paths = []
      @entries_by_dir = {}
      @read_responses = {}
    end

    def write(path, data)
      @writes[path] = data
    end

    def exists?(path)
      @exist_paths.include?(path)
    end

    def list(path, **)
      @entries_by_dir.fetch(path, [])
    end

    def read(path, format: "text", **)
      bytes = @read_responses.fetch(path)
      format == "bytes" ? bytes.b : bytes
    end
  end

  # Fake E2B sandbox tracking create / resume / pause / kill.
  class FakeSandbox
    attr_reader :commands, :files, :sandbox_id
    attr_reader :paused_count, :resume_timeouts

    def initialize(sandbox_id: "sbx-fake", on_pause: nil, on_resume: nil)
      @commands = FakeCommands.new
      @files = FakeFiles.new
      @sandbox_id = sandbox_id
      @paused_count = 0
      @resume_timeouts = []
      @killed = false
      @on_pause = on_pause
      @on_resume = on_resume
    end

    def pause
      @on_pause&.call(self)
      @paused_count += 1
    end

    def resume(timeout: nil)
      @on_resume&.call(self)
      @resume_timeouts << timeout
    end

    def kill
      @killed = true
    end

    def killed?
      @killed
    end
  end

  def fake_session
    session = Object.new
    def session.close = nil
    session
  end

  # Stub E2B::Sandbox.create / .connect and PiAgent.session for the block.
  # `on_connect` is invoked with the sandbox_id requested.
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

  def with_e2b(create: nil, connect: nil, session: fake_session, on_connect: nil)
    create_original  = E2B::Sandbox.method(:create)
    connect_original = E2B::Sandbox.method(:connect)
    session_original = PiAgent.method(:session)
    E2B::Sandbox.define_singleton_method(:create)  { |**| create } if create
    E2B::Sandbox.define_singleton_method(:connect) { |id, **| on_connect&.call(id); connect } if connect
    PiAgent.define_singleton_method(:session) { |*, **| session }
    yield
  ensure
    E2B::Sandbox.define_singleton_method(:create,  create_original)
    E2B::Sandbox.define_singleton_method(:connect, connect_original)
    PiAgent.define_singleton_method(:session, session_original)
  end

  test "session_dir is the in-sandbox session path" do
    assert_equal Agent::Runtime::E2b::SESSION_DIR, @runtime.session_dir.to_s
  end

  test "first turn creates a sandbox, pauses it, and records the id on the conversation" do
    sandbox = FakeSandbox.new(sandbox_id: "sbx-new")

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal 1, sandbox.paused_count, "sandbox paused at end of turn"
    refute sandbox.killed?, "sandbox not killed — the next turn will resume it"
    assert_equal "sbx-new", @conversation.reload.e2b_sandbox_id
  end

  test "discards .mcp.json before pausing so the snapshot holds no bearer tokens" do
    mcp_path = "#{Agent::Runtime::E2b::WORKSPACE_DIR}/#{Agent::McpConfig::FILENAME}"
    runs_at_pause = nil
    sandbox = FakeSandbox.new(
      sandbox_id: "sbx-new",
      on_pause: ->(s) { runs_at_pause = s.commands.runs.dup }
    )

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_includes runs_at_pause, "rm -f #{mcp_path}",
                    "mcp config deleted before pause — a paused snapshot must not hold tokens"
  end

  test "subsequent turns resume the stored sandbox, do not create a fresh one" do
    @conversation.update_column(:e2b_sandbox_id, "sbx-existing")
    sandbox = FakeSandbox.new(sandbox_id: "sbx-existing")
    connected_with = nil

    with_e2b(connect: sandbox, on_connect: ->(id) { connected_with = id }) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal "sbx-existing", connected_with
    assert_equal [ Agent::Runtime::E2b::SANDBOX_TIMEOUT ], sandbox.resume_timeouts,
                 "resumed with the runtime's timeout"
    assert_equal 1, sandbox.paused_count, "paused again at end of turn"
    assert_equal "sbx-existing", @conversation.reload.e2b_sandbox_id,
                 "id unchanged when same sandbox is reused"
  end

  test "a missing stored sandbox falls back to fresh provision and clears the stale id" do
    @conversation.update_column(:e2b_sandbox_id, "sbx-gone")
    fresh_sandbox = FakeSandbox.new(sandbox_id: "sbx-replacement")

    # E2B::Sandbox.connect raises NotFoundError when the id is gone
    # (evicted, killed externally, paused-state expired).
    with_stub(E2B::Sandbox, :connect, ->(_id, **_) { raise E2B::NotFoundError, "no such sandbox" }) do
      with_e2b(create: fresh_sandbox) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
      end
    end

    assert_equal "sbx-replacement", @conversation.reload.e2b_sandbox_id,
                 "the new sandbox's id replaces the stale one"
    assert_equal 1, fresh_sandbox.paused_count
  end

  test "pause failure best-effort kills the sandbox and clears the id" do
    # If pause fails the VM might still be alive — left as an orphan it
    # would leak (no auto-cleanup on E2B), so we kill and clear, letting
    # the next turn provision fresh.
    sandbox = FakeSandbox.new(
      sandbox_id: "sbx-pause-fail",
      on_pause: ->(_s) { raise E2B::E2BError, "pause http 500" }
    )

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert sandbox.killed?, "fallback to kill when pause fails"
    assert_nil @conversation.reload.e2b_sandbox_id, "stale id cleared"
  end

  test "uploads the app's pi extensions into the sandbox each turn" do
    sandbox = FakeSandbox.new

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    staged = sandbox.files.writes.keys.grep(%r{\A#{Agent::Runtime::E2b::EXTENSIONS_DIR}/})
    assert staged.any? { |path| path.end_with?("/web-tools.ts") },
           "web-tools extension uploaded into the sandbox"
  end

  test "extension_paths point at the uploaded extensions inside the sandbox" do
    paths = @runtime.extension_paths.map(&:to_s)

    assert_includes paths, "#{Agent::Runtime::E2b::EXTENSIONS_DIR}/web-tools.ts"
  end

  test "drains the .pi/skills/.imports sentinel into ImportSkillJob enqueues" do
    sandbox = FakeSandbox.new
    imports_path = "#{Agent::Runtime::E2b::WORKSPACE_DIR}/.pi/skills/.imports"
    sandbox.files.exist_paths << imports_path
    sandbox.files.read_responses[imports_path] = <<~TXT
      anthropics/skills/skills/pdf
      # comment
      anthropics/skills/skills/xlsx
    TXT

    assert_enqueued_jobs 2, only: ImportSkillJob do
      with_e2b(create: sandbox) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
      end
    end
  end

  test "uploads the team's enabled skills into the sandbox skills tree alongside repo skills" do
    skill = @conversation.team.skills.create!(slug: "summarize", description: "x")
    skill.replace_skill_md!("# body")
    skill.save!
    sandbox = FakeSandbox.new

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    staged = "#{Agent::Runtime::E2b::WORKSPACE_DIR}/.pi/skills/summarize/SKILL.md"
    assert_equal "# body", sandbox.files.writes[staged]
  end

  test "fresh sandbox without a baked template uploads the repo .pi/skills/ tree from the host" do
    sandbox = FakeSandbox.new
    # BAKED_REPO_SKILLS_DIR is NOT in exist_paths — simulates a legacy
    # template that predates the bake. The runtime falls back to
    # per-file upload.
    with_skills_source do |source|
      FileUtils.mkdir_p(source.join("summarize"))
      File.write(source.join("summarize/SKILL.md"), "# repo skill")
      with_e2b(create: sandbox) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
      end
    end

    repo_uploads = sandbox.files.writes.keys.grep(%r{\A#{Agent::Runtime::E2b::WORKSPACE_DIR}/\.pi/skills/[^/]+/SKILL\.md\z})
    assert repo_uploads.any?, "legacy template falls back to host upload"
  end

  test "fresh sandbox with a baked template copies repo skills with one sandbox-local cp" do
    sandbox = FakeSandbox.new
    sandbox.files.exist_paths << Agent::Runtime::E2b::BAKED_REPO_SKILLS_DIR
    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    # No per-file uploads from the host
    repo_uploads = sandbox.files.writes.keys.grep(%r{\A#{Agent::Runtime::E2b::WORKSPACE_DIR}/\.pi/skills/[^/]+/SKILL\.md\z})
    assert_empty repo_uploads, "baked template path must not upload repo files"

    # One cp -r from the baked dir to the workspace
    cp_calls = sandbox.commands.runs.select { |c|
      c.include?("cp -r") && c.include?(Agent::Runtime::E2b::BAKED_REPO_SKILLS_DIR)
    }
    assert cp_calls.any?, "expected a cp -r from the baked dir"
  end

  test "resumed sandbox skips team-skill rewrite when the signature marker matches the DB" do
    @conversation.update_column(:e2b_sandbox_id, "sbx-warm")
    skill = @conversation.team.skills.create!(slug: "tldr", description: "x")
    skill.replace_skill_md!("# body")
    skill.save!

    runtime = Agent::Runtime::E2b.new(conversation: @conversation)
    signature = Skill.team_signature(@conversation.team)

    dest_root = "#{Agent::Runtime::E2b::WORKSPACE_DIR}/.pi/skills"
    marker_path = "#{dest_root}/#{Agent::Runtime::E2b::TEAM_SKILLS_MARKER}"
    sandbox = FakeSandbox.new(sandbox_id: "sbx-warm")
    sandbox.files.exist_paths << marker_path
    sandbox.files.read_responses[marker_path] = signature

    with_e2b(connect: sandbox) do
      runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    # No file rewrites or rm-rfs for team skills when the signature matches.
    refute sandbox.files.writes.key?("#{dest_root}/tldr/SKILL.md"),
           "matching signature must skip the full team-skill rewrite"
  end

  test "resumed sandbox restages team skills when the signature drifts" do
    @conversation.update_column(:e2b_sandbox_id, "sbx-warm")
    skill = @conversation.team.skills.create!(slug: "tldr", description: "x")
    skill.replace_skill_md!("# body")
    skill.save!

    dest_root = "#{Agent::Runtime::E2b::WORKSPACE_DIR}/.pi/skills"
    marker_path = "#{dest_root}/#{Agent::Runtime::E2b::TEAM_SKILLS_MARKER}"
    sandbox = FakeSandbox.new(sandbox_id: "sbx-warm")
    sandbox.files.exist_paths << marker_path
    sandbox.files.read_responses[marker_path] = "stale-signature"

    with_e2b(connect: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal "# body", sandbox.files.writes["#{dest_root}/tldr/SKILL.md"],
                 "stale signature triggers a full restage"
    assert sandbox.files.writes.key?(marker_path), "marker rewritten after the restage"
  end

  test "resumed sandbox skips repo upload (trusts pause/resume) but still re-stages team skills" do
    @conversation.update_column(:e2b_sandbox_id, "sbx-warm")
    skill = @conversation.team.skills.create!(slug: "summarize", description: "x")
    skill.replace_skill_md!("# team body")
    skill.save!
    sandbox = FakeSandbox.new(sandbox_id: "sbx-warm")

    with_e2b(connect: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    # Team skill always re-staged
    team_path = "#{Agent::Runtime::E2b::WORKSPACE_DIR}/.pi/skills/summarize/SKILL.md"
    assert_equal "# team body", sandbox.files.writes[team_path]

    # Repo skills NOT re-uploaded on resume
    repo_uploads = sandbox.files.writes.keys.grep(%r{\A#{Agent::Runtime::E2b::WORKSPACE_DIR}/\.pi/skills/(?!summarize/)[^/]+/}).reject { |p| p.start_with?("#{Agent::Runtime::E2b::WORKSPACE_DIR}/.pi/skills/summarize/") }
    assert_empty repo_uploads,
                 "resumed sandbox must NOT re-upload repo skills (trusts pause/resume)"
  end

  test "resumed sandbox removes stale team-skill dirs no longer enabled" do
    @conversation.update_column(:e2b_sandbox_id, "sbx-warm")
    # Pretend a previously-staged team skill is still sitting in the sandbox.
    dest_root = "#{Agent::Runtime::E2b::WORKSPACE_DIR}/.pi/skills"
    sandbox = FakeSandbox.new(sandbox_id: "sbx-warm")
    sandbox.files.exist_paths << dest_root
    sandbox.files.entries_by_dir[dest_root] = [
      OpenStruct.new(path: "#{dest_root}/orphaned", file?: false)
    ]

    with_e2b(connect: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    rm_calls = sandbox.commands.runs.select { |c| c.include?("rm -rf") && c.include?("orphaned") }
    assert rm_calls.any?, "orphan team-skill dir gets cleaned up on resume"
  end

  test "ingests touched team skills from the sandbox at turn end" do
    sandbox = FakeSandbox.new
    skill_dir = "#{Agent::Runtime::E2b::WORKSPACE_DIR}/.pi/skills/code-review"
    skill_md_path = "#{skill_dir}/SKILL.md"
    sandbox.files.exist_paths << skill_dir
    sandbox.files.entries_by_dir[skill_dir] = [
      OpenStruct.new(path: skill_md_path, file?: true)
    ]
    sandbox.files.read_responses[skill_md_path] = <<~MD
      ---
      name: code-review
      description: From the sandbox.
      ---
      # body
    MD

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        # Adapter would normally call this as it sees the write event.
        @runtime.note_skill_touched("code-review")
      end
    end

    skill = @conversation.team.skills.find_by(slug: "code-review")
    assert_not_nil skill, "touched slug was read from the sandbox + ingested"
    assert_equal "From the sandbox.", skill.description
  end

  test "does not ingest sandbox files for slugs the adapter did not record" do
    sandbox = FakeSandbox.new
    # Pretend the agent wrote here, but the adapter never recorded the
    # slug — sandbox state alone must not produce a team row.
    skill_dir = "#{Agent::Runtime::E2b::WORKSPACE_DIR}/.pi/skills/decoy"
    sandbox.files.exist_paths << skill_dir
    sandbox.files.entries_by_dir[skill_dir] = [
      OpenStruct.new(path: "#{skill_dir}/SKILL.md", file?: true)
    ]
    sandbox.files.read_responses["#{skill_dir}/SKILL.md"] = "# never"

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_nil @conversation.team.skills.find_by(slug: "decoy")
  end

  test "projects the conversation's uploaded files into the sandbox uploads dir" do
    sandbox = FakeSandbox.new
    message = @conversation.messages.create!(role: :user, content: "hi", streaming_status: :done)
    message.files.attach(io: StringIO.new("file contents"), filename: "notes.txt", content_type: "text/plain")

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    staged = "#{Agent::Runtime::E2b::WORKSPACE_DIR}/uploads/notes.txt"
    assert_equal "file contents", sandbox.files.writes[staged]
  end

  test "runtime_info reports the runtime name and the sandbox id" do
    sandbox = FakeSandbox.new(sandbox_id: "sbx-99")

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal({ "runtime" => "e2b", "sandbox_id" => "sbx-99" }, @runtime.runtime_info)
  end

  test "collects artifacts from the sandbox before the pause" do
    art_path = "#{Agent::Runtime::E2b::ARTIFACTS_DIR}/report.csv"
    paused_with_artifacts = nil

    sandbox = FakeSandbox.new(
      on_pause: ->(_s) { paused_with_artifacts = @runtime.artifacts.map { |a| a[:filename] } }
    )
    sandbox.files.exist_paths << Agent::Runtime::E2b::ARTIFACTS_DIR
    sandbox.files.entries_by_dir[Agent::Runtime::E2b::ARTIFACTS_DIR] = [
      E2B::Models::EntryInfo.new(
        name: "report.csv", type: E2B::Models::FileType::FILE,
        path: art_path, modified_time: Time.now + 5
      )
    ]
    sandbox.files.read_responses[art_path] = "a,b\n1,2\n"

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal [ "report.csv" ], paused_with_artifacts,
                 "artifacts collected before pause — a paused sandbox is unreachable"
    assert_equal "a,b\n1,2\n", @runtime.artifacts.first[:io].read
  end

  test "skips artifacts whose modified_time predates the turn" do
    art_path = "#{Agent::Runtime::E2b::ARTIFACTS_DIR}/old.csv"
    sandbox = FakeSandbox.new
    sandbox.files.exist_paths << Agent::Runtime::E2b::ARTIFACTS_DIR
    sandbox.files.entries_by_dir[Agent::Runtime::E2b::ARTIFACTS_DIR] = [
      E2B::Models::EntryInfo.new(
        name: "old.csv", type: E2B::Models::FileType::FILE,
        path: art_path, modified_time: Time.now - 3600
      )
    ]
    sandbox.files.read_responses[art_path] = "stale"

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_empty @runtime.artifacts
  end

  test "skips artifacts above the size cap" do
    big_path = "#{Agent::Runtime::E2b::ARTIFACTS_DIR}/huge.bin"
    ok_path = "#{Agent::Runtime::E2b::ARTIFACTS_DIR}/ok.csv"
    sandbox = FakeSandbox.new
    sandbox.files.exist_paths << Agent::Runtime::E2b::ARTIFACTS_DIR
    sandbox.files.entries_by_dir[Agent::Runtime::E2b::ARTIFACTS_DIR] = [
      E2B::Models::EntryInfo.new(name: "huge.bin", type: E2B::Models::FileType::FILE,
                                 path: big_path, size: 11.megabytes, modified_time: Time.now + 5),
      E2B::Models::EntryInfo.new(name: "ok.csv", type: E2B::Models::FileType::FILE,
                                 path: ok_path, size: 12, modified_time: Time.now + 5)
    ]
    sandbox.files.read_responses[ok_path] = "a,b\n1,2\n"

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal [ "ok.csv" ], @runtime.artifacts.map { |a| a[:filename] }
  end

  test "preserves the subdirectory in the artifact filename" do
    art_path = "#{Agent::Runtime::E2b::ARTIFACTS_DIR}/reports/q4.csv"
    sandbox = FakeSandbox.new
    sandbox.files.exist_paths << Agent::Runtime::E2b::ARTIFACTS_DIR
    sandbox.files.entries_by_dir[Agent::Runtime::E2b::ARTIFACTS_DIR] = [
      E2B::Models::EntryInfo.new(name: "reports", type: E2B::Models::FileType::DIRECTORY,
                                 path: "#{Agent::Runtime::E2b::ARTIFACTS_DIR}/reports",
                                 modified_time: Time.now + 5)
    ]
    sandbox.files.entries_by_dir["#{Agent::Runtime::E2b::ARTIFACTS_DIR}/reports"] = [
      E2B::Models::EntryInfo.new(name: "q4.csv", type: E2B::Models::FileType::FILE,
                                 path: art_path, size: 8, modified_time: Time.now + 5)
    ]
    sandbox.files.read_responses[art_path] = "csv data"

    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_equal [ "reports/q4.csv" ], @runtime.artifacts.map { |a| a[:filename] }
  end

  test "no-op when the artifacts dir was never created" do
    sandbox = FakeSandbox.new
    with_e2b(create: sandbox) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| nil }
    end

    assert_empty @runtime.artifacts
  end

  test ".kill_sandbox swallows NotFoundError so eviction is idempotent" do
    with_stub(E2B::Sandbox, :kill, ->(_id, **_) { raise E2B::NotFoundError, "already gone" }) do
      assert_nothing_raised { Agent::Runtime::E2b.kill_sandbox("sbx-doesnt-exist") }
    end
  end

  test ".kill_sandbox is a no-op when the id is blank" do
    # Callers (Conversation#before_destroy, EvictPausedSandboxesJob) may
    # invoke with nil; an HTTP call against a nil id would 404 and log
    # noise pointlessly.
    called = false
    with_stub(E2B::Sandbox, :kill, ->(_id, **_) { called = true }) do
      Agent::Runtime::E2b.kill_sandbox(nil)
      Agent::Runtime::E2b.kill_sandbox("")
    end
    refute called
  end
end
