require "test_helper"

class Agent::WorkspaceCleanupTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir("cleanup-test"))
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  def cleanup(user_id: 1, conversation_id: 2)
    Agent::WorkspaceCleanup.new(user_id: user_id, conversation_id: conversation_id, root: @root)
  end

  def build_scope(user_id: 1, conversation_id: 2)
    scope = @root.join("u#{user_id}", "c#{conversation_id}")
    FileUtils.mkdir_p(scope.join("sessions"))
    FileUtils.mkdir_p(scope.join("workspace/repo"))
    scope.join("sessions/transcript.jsonl").write("session-data")
    scope.join("workspace/repo/main.rb").write("puts 1" * 10)
    scope.join("workspace/wip.txt").write("uncommitted")
    scope
  end

  test "rejects zero, negative, string, float, and path-fragment ids" do
    [ 0, -3, "1", "1/../2", 1.5, nil ].each do |bad|
      assert_raises(ArgumentError, "id #{bad.inspect} should be rejected") do
        Agent::WorkspaceCleanup.new(user_id: bad, conversation_id: 2, root: @root)
      end
      assert_raises(ArgumentError) do
        Agent::WorkspaceCleanup.new(user_id: 1, conversation_id: bad, root: @root)
      end
    end
  end

  test "builds exactly the u<ID>/c<ID> scope shape beneath the root" do
    c = cleanup(user_id: 7, conversation_id: 42)
    assert_equal @root.join("u7", "c42"), c.scope_dir
    assert_equal @root.join("u7", "c42", "workspace"), c.workspace_dir
  end

  test "evict_workspace! deletes workspace/ and preserves sessions/" do
    scope = build_scope
    bytes = cleanup.evict_workspace!

    refute scope.join("workspace").exist?, "workspace/ should be gone"
    assert_equal "session-data", scope.join("sessions/transcript.jsonl").read
    assert_operator bytes, :>, 0
  end

  test "evict_workspace! is idempotent when workspace/ is already absent" do
    FileUtils.mkdir_p(@root.join("u1", "c2", "sessions"))
    assert_equal 0, cleanup.evict_workspace!
  end

  test "evict_workspace! raises when deletion leaves the workspace behind" do
    scope = build_scope

    with_stub(FileUtils, :rm_r, ->(*) { }) do
      assert_raises(Errno::EIO) { cleanup.evict_workspace! }
    end

    assert scope.join("workspace").exist?
  end

  test "destroy_scope! removes the whole scope including sessions, idempotently" do
    scope = build_scope
    cleanup.destroy_scope!
    refute scope.exist?

    assert_equal 0, cleanup.destroy_scope!
  end

  test "a symlink at the workspace path is unlinked, never followed" do
    target = Pathname.new(Dir.mktmpdir("cleanup-target"))
    target.join("precious.txt").write("keep me")
    scope = @root.join("u1", "c2")
    FileUtils.mkdir_p(scope)
    File.symlink(target, scope.join("workspace"))

    cleanup.evict_workspace!

    refute File.symlink?(scope.join("workspace")), "link should be removed"
    assert_equal "keep me", target.join("precious.txt").read
  ensure
    FileUtils.rm_rf(target)
  end

  test "refuses deletion when a parent symlink resolves outside the root" do
    target = Pathname.new(Dir.mktmpdir("cleanup-escape"))
    FileUtils.mkdir_p(target.join("c2/workspace"))
    File.symlink(target, @root.join("u1"))

    assert_raises(Agent::WorkspaceCleanup::UnsafePath) { cleanup.evict_workspace! }
    assert target.join("c2/workspace").exist?, "escape target must be untouched"
  ensure
    FileUtils.rm_rf(target)
  end

  test "bytes_under measures without following symlinks" do
    build_scope
    outside = Pathname.new(Dir.mktmpdir("cleanup-bytes"))
    outside.join("huge.bin").write("x" * 10_000)
    File.symlink(outside, @root.join("u1/c2/workspace/link"))

    linked = Agent::WorkspaceCleanup.bytes_under(@root.join("u1/c2/workspace"))
    assert_operator linked, :<, 10_000, "symlink target must not be counted"
  ensure
    FileUtils.rm_rf(outside)
  end

  test "bytes_under of a missing path is zero" do
    assert_equal 0, Agent::WorkspaceCleanup.bytes_under(@root.join("nope"))
  end

  test "bytes_under surfaces permission failures" do
    with_stub(File, :lstat, ->(*) { raise Errno::EACCES }) do
      assert_raises(Errno::EACCES) { Agent::WorkspaceCleanup.bytes_under(@root) }
    end
  end

  test "free_space reports the filesystem holding the root" do
    space = Agent::WorkspaceCleanup.free_space(root: @root)
    assert space, "df on a real directory should parse"
    assert_operator space.total_kb, :>, 0
    assert_includes 0.0..100.0, space.free_percent
  end

  test "free_space logs and returns nil for a missing root" do
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    with_stub(Rails, :logger, -> { logger }) do
      assert_nil Agent::WorkspaceCleanup.free_space(root: @root.join("absent"))
    end
    assert_match(/event=persistent_free_space_failed reason=missing_root/, log.string)
  end

  test "free_space times out safely and logs the failure" do
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    with_stub(Rails, :logger, -> { logger }) do
      with_stub(Timeout, :timeout, ->(*) { raise Timeout::Error, "timed out" }) do
        assert_nil Agent::WorkspaceCleanup.free_space(root: @root)
      end
    end
    assert_match(/event=persistent_free_space_failed reason=exception/, log.string)
    assert_match(/Timeout::Error/, log.string)
  end

  test "free_space is nil when df fails or emits garbage" do
    fail_status = Object.new
    def fail_status.success? = false
    with_stub(Open3, :capture3, ->(*) { [ "", "boom", fail_status ] }) do
      assert_nil Agent::WorkspaceCleanup.free_space(root: @root)
    end

    ok_status = Object.new
    def ok_status.success? = true
    with_stub(Open3, :capture3, ->(*) { [ "header only\n", "", ok_status ] }) do
      assert_nil Agent::WorkspaceCleanup.free_space(root: @root)
    end

    with_stub(Open3, :capture3, ->(*) { [ "h\n/dev/x notanumber 0 huh 1% /\n", "", ok_status ] }) do
      assert_nil Agent::WorkspaceCleanup.free_space(root: @root)
    end
  end

  test "free_space is nil when total blocks are zero" do
    ok_status = Object.new
    def ok_status.success? = true
    with_stub(Open3, :capture3, ->(*) { [ "h\n/dev/x 0 0 0 100% /\n", "", ok_status ] }) do
      assert_nil Agent::WorkspaceCleanup.free_space(root: @root)
    end
  end

  test "scan_scopes lists u*/c* directories and skips symlinks and strays" do
    build_scope(user_id: 3, conversation_id: 9)
    build_scope(user_id: 1, conversation_id: 4)
    FileUtils.mkdir_p(@root.join("stray"))
    FileUtils.mkdir_p(@root.join("u3/not-a-scope"))
    File.symlink(@root.join("u3"), @root.join("u99"))

    scopes = Agent::WorkspaceCleanup.scan_scopes(root: @root)
      .map { |s| [ s[:user_id], s[:conversation_id] ] }.sort

    assert_equal [ [ 1, 4 ], [ 3, 9 ] ], scopes
  end
end
