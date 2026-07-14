require "test_helper"

class Agent::WorkspaceReportTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir("report-test"))
    @user = User.create!(email: "report-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @conversation = @user.conversations.create!(runtime_state: { "runtime" => "docker" })
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  def build_scope(user_id, conversation_id)
    scope = @root.join("u#{user_id}", "c#{conversation_id}")
    FileUtils.mkdir_p(scope.join("sessions"))
    FileUtils.mkdir_p(scope.join("workspace"))
    scope.join("sessions/t.jsonl").write("ss")
    scope.join("workspace/f.txt").write("wwww")
    scope
  end

  test "rows are deterministic, byte-accounted, and flag orphans" do
    build_scope(@user.id, @conversation.id)
    build_scope(999_999, 999_999)

    rows = Agent::WorkspaceReport.new(root: @root).rows

    assert_equal [ [ @user.id, @conversation.id ], [ 999_999, 999_999 ] ].sort,
                 rows.map { |r| [ r[:user_id], r[:conversation_id] ] }

    known = rows.find { |r| r[:conversation_id] == @conversation.id }
    assert known[:conversation]
    refute known[:orphan]
    assert_equal "docker", known[:runtime]
    assert_equal false, known[:archived]
    assert_equal false, known[:inflight]
    assert_equal 2, known[:sessions_bytes]
    assert_equal 4, known[:workspace_bytes]
    assert_equal 6, known[:total_bytes]

    orphan = rows.find { |r| r[:conversation_id] == 999_999 }
    assert orphan[:orphan]
    refute orphan[:conversation]
    assert_nil orphan[:runtime]
  end

  test "rows reflect workflow, inflight, and eviction state" do
    build_scope(@user.id, @conversation.id)
    WorkflowRun.create!(team: @user.personal_team, conversation: @conversation, status: :completed)
    @conversation.messages.create!(role: :assistant, content: "", streaming_status: :pending)
    @conversation.update!(docker_workspace_evicted_at: Time.current,
                          docker_workspace_eviction_reason: "low_disk")

    row = Agent::WorkspaceReport.new(root: @root).rows.sole

    assert_equal "completed", row[:workflow_status]
    assert row[:inflight]
    assert_equal "low_disk", row[:eviction_reason]
    assert_not_nil row[:evicted_at]
  end

  test "to_s emits stable key=value lines with free-space header" do
    build_scope(@user.id, @conversation.id)

    out = Agent::WorkspaceReport.new(root: @root).to_s

    assert_match(/\Aroot=#{Regexp.escape(@root.to_s)} free_percent=[\d.]+ total_kb=\d+ available_kb=\d+$/, out)
    assert_match(/^scopes=1 total_bytes=6$/, out)
    assert_match(/^scope user_id=#{@user.id} conversation_id=#{@conversation.id} total_bytes=6 sessions_bytes=2 workspace_bytes=4 conversation=true runtime=docker/, out)
    assert_match(/orphan=false$/, out)
  end

  test "raises ScanError when the root is missing" do
    assert_raises(Agent::WorkspaceReport::ScanError) do
      Agent::WorkspaceReport.new(root: @root.join("absent")).rows
    end
  end

  test "to_s raises ScanError when free space cannot be determined" do
    with_stub(Agent::WorkspaceCleanup, :free_space, ->(**) { nil }) do
      assert_raises(Agent::WorkspaceReport::ScanError) do
        Agent::WorkspaceReport.new(root: @root).to_s
      end
    end
  end
end
