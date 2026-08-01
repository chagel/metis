require "test_helper"

class Agent::Runtime::LocalTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rt@example.com", password: "password123")
    @conversation = @user.conversations.create!
    @runtime = Agent::Runtime::Local.new(conversation: @conversation)
    @workspace = Agent::Workspace.persistent(@conversation)
  end

  teardown do
    FileUtils.rm_rf(Agent::Workspace::PERSISTENT_ROOT.join("u#{@user.id}"))
  end

  # Swap PiAgent.session so #run never spawns a real pi process.
  def with_pi_session(session)
    original = PiAgent.method(:session)
    PiAgent.define_singleton_method(:session) { |*, **| session }
    yield
  ensure
    PiAgent.define_singleton_method(:session, original)
  end

  def fake_session
    session = Object.new
    def session.closed? = @closed
    def session.close = (@closed = true)
    session
  end

  test "session_dir is the persistent workspace session directory" do
    assert_equal @workspace.session_dir, @runtime.session_dir
  end

  test "runtime_info names the local runtime" do
    assert_equal({ "runtime" => "local" }, @runtime.runtime_info)
  end

  test "extension_paths offers the repo's bundled pi extensions in place" do
    paths = @runtime.extension_paths.map(&:to_s)

    assert paths.any? { |path| path.end_with?(".pi/extensions/web-tools/index.ts") },
           "web-tools extension is offered to pi"
    assert paths.all? { |path| File.exist?(path) }, "extension files exist on this host"
  end

  test "run ingests only the slugs the adapter recorded via note_skill_touched" do
    session = fake_session
    skill_md = <<~MD
      ---
      name: code-review
      description: Walk the diff for security + invariants.
      ---
      # body
    MD

    with_pi_session(session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        # Simulate what the adapter would do mid-turn: agent wrote a
        # skill, adapter parsed the tool event, called note_skill_touched.
        dir = @workspace.skills_dir.join("code-review")
        FileUtils.mkdir_p(dir)
        File.write(dir.join("SKILL.md"), skill_md)
        @runtime.note_skill_touched("code-review")

        # An untouched skill on disk must NOT get ingested — the slug
        # set is the authority.
        FileUtils.mkdir_p(@workspace.skills_dir.join("decoy"))
        File.write(@workspace.skills_dir.join("decoy/SKILL.md"), "# never seen")
      end
    end

    skill = @conversation.team.skills.find_by(slug: "code-review")
    assert_not_nil skill, "touched skill was ingested"
    assert_equal "Walk the diff for security + invariants.", skill.description
    assert_nil @conversation.team.skills.find_by(slug: "decoy"),
               "decoy skill on disk is invisible without an adapter signal"
  end

  test "run provisions the workspace and yields the session" do
    session = fake_session
    yielded = nil

    with_pi_session(session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |s|
        yielded = s
        assert Dir.exist?(@workspace.workspace_dir), "workspace provisioned"
      end
    end

    assert_equal session, yielded
    assert session.closed?, "session closed by the runtime"
  end

  test "run keeps the scope between turns and never archives" do
    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        File.write(@workspace.workspace_dir.join("turn1.rb"), "code")
      end
    end

    seen_on_turn2 = nil
    with_pi_session(fake_session) do
      Agent::Runtime::Local.new(conversation: @conversation).run(pi_args: [ "--mode", "rpc" ]) do |_s|
        seen_on_turn2 = File.exist?(@workspace.workspace_dir.join("turn1.rb"))
      end
    end

    assert seen_on_turn2, "turn 1's workspace files are still there on turn 2 (pi-native persistence)"
  end

  test "run projects the conversation's uploaded files into uploads/" do
    message = @conversation.messages.create!(role: :user, content: "hi", streaming_status: :done)
    message.files.attach(io: StringIO.new("a,b\n1,2\n"), filename: "data.csv", content_type: "text/csv")
    staged = @workspace.uploads_dir.join("data.csv")

    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        assert File.exist?(staged), "upload projected before the run"
      end
    end

    assert_equal "a,b\n1,2\n", File.read(staged)
  end

  test "run closes the session even when the block raises" do
    session = fake_session

    assert_raises(RuntimeError) do
      with_pi_session(session) do
        @runtime.run(pi_args: [ "--mode", "rpc" ]) { |_s| raise "turn failed" }
      end
    end

    assert session.closed?
  end

  test "collects files the agent wrote under workspace/artifacts/" do
    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        FileUtils.mkdir_p(@workspace.artifacts_dir)
        File.write(@workspace.artifacts_dir.join("report.csv"), "a,b\n1,2\n")
      end
    end

    assert_equal 1, @runtime.artifacts.size
    artifact = @runtime.artifacts.first
    assert_equal "report.csv", artifact[:filename]
    assert_equal "a,b\n1,2\n", artifact[:io].read
  end

  test "skips symlinked artifacts" do
    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        FileUtils.mkdir_p(@workspace.artifacts_dir)
        secret = @workspace.workspace_dir.join("secret.txt")
        File.write(secret, "host secret")
        File.symlink(secret, @workspace.artifacts_dir.join("secret.txt"))
      end
    end

    assert_empty @runtime.artifacts
  end

  test "preserves the subdirectory in the filename so siblings don't collide" do
    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        FileUtils.mkdir_p(@workspace.artifacts_dir.join("reports"))
        FileUtils.mkdir_p(@workspace.artifacts_dir.join("drafts"))
        File.write(@workspace.artifacts_dir.join("reports/q4.csv"), "final")
        File.write(@workspace.artifacts_dir.join("drafts/q4.csv"), "wip")
      end
    end

    names = @runtime.artifacts.map { |a| a[:filename] }.sort
    assert_equal [ "drafts/q4.csv", "reports/q4.csv" ], names
  end

  test "skips artifacts above the size cap" do
    # Sparse file — File.size reports 11MB without actually using disk.
    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        FileUtils.mkdir_p(@workspace.artifacts_dir)
        File.write(@workspace.artifacts_dir.join("ok.txt"), "small")
        File.open(@workspace.artifacts_dir.join("huge.bin"), "w") { |f| f.truncate(11.megabytes) }
      end
    end

    names = @runtime.artifacts.map { |a| a[:filename] }
    assert_equal [ "ok.txt" ], names
  end

  test "ignores artifacts older than this turn" do
    FileUtils.mkdir_p(@workspace.artifacts_dir)
    stale = @workspace.artifacts_dir.join("old.txt")
    File.write(stale, "from a previous turn")
    File.utime(stale.mtime - 3600, stale.mtime - 3600, stale)

    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        File.write(@workspace.artifacts_dir.join("fresh.txt"), "from this turn")
      end
    end

    names = @runtime.artifacts.map { |a| a[:filename] }
    assert_equal [ "fresh.txt" ], names
  end

  test "run stages the conversation's connectors into .mcp.json" do
    @conversation.team.connectors.create!(name: "fs", transport: :stdio, definition: { "command" => "npx" })

    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        config = JSON.parse(File.read(@workspace.workspace_dir.join(".mcp.json")))
        assert_equal [ "fs" ], config["mcpServers"].keys
      end
    end
  end

  test "control_session opens an rpc session, yields it, and closes it" do
    session = fake_session
    def session.available_models = [ { "id" => "m", "provider" => "p" } ]

    result = with_pi_session(session) do
      Agent::Runtime::Local.control_session { |s| s.available_models }
    end

    assert_equal [ { "id" => "m", "provider" => "p" } ], result
    assert session.closed?
  end

  test "Agent::Runtime.control_session dispatches to the configured runtime" do
    session = fake_session
    def session.available_models = [ "ok" ]

    result = with_pi_session(session) do
      Agent::Runtime.control_session { |s| s.available_models }
    end

    assert_equal [ "ok" ], result
  end
end
