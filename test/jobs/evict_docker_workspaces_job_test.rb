require "test_helper"

class EvictDockerWorkspacesJobTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "evict-#{SecureRandom.hex(4)}@example.com", password: "password123")
  end

  teardown do
    FileUtils.rm_rf(Agent::Workspace::PERSISTENT_ROOT.join("u#{@user.id}"))
  end

  def docker_conversation(last_used: nil, updated: nil, archived: nil)
    conversation = @user.conversations.create!(runtime_state: { "runtime" => "docker" })
    conversation.update_columns(
      docker_workspace_last_used_at: last_used,
      archived_at: archived,
      updated_at: updated || conversation.updated_at
    )
    build_scope(conversation)
    conversation
  end

  def build_scope(conversation)
    workspace = Agent::Workspace.persistent(conversation)
    workspace.ensure!
    workspace.session_dir.join("t.jsonl").write("session")
    workspace.workspace_dir.join("wip.txt").write("files")
    workspace
  end

  # Retention tests must not depend on the CI host's real disk — pin free
  # space above the low watermark so the emergency pass stays quiet.
  def perform_with_healthy_disk
    with_stub(Agent::WorkspaceCleanup, :free_space, ->(**) { Agent::WorkspaceCleanup::FreeSpace.new(100, 50) }) do
      EvictDockerWorkspacesJob.perform_now
    end
  end

  def assert_evicted(conversation, reason)
    conversation.reload
    workspace = Agent::Workspace.persistent(conversation)
    refute workspace.workspace_dir.exist?, "workspace/ should be reclaimed"
    assert workspace.session_dir.join("t.jsonl").exist?, "sessions/ must survive"
    assert_equal reason, conversation.docker_workspace_eviction_reason
    assert_not_nil conversation.docker_workspace_evicted_at
  end

  def assert_untouched(conversation)
    conversation.reload
    assert Agent::Workspace.persistent(conversation).workspace_dir.exist?, "workspace/ must stay"
    assert_nil conversation.docker_workspace_evicted_at
  end

  test "evicts an ordinary conversation idle past its window, preserving sessions" do
    conversation = docker_conversation(last_used: 8.days.ago, updated: 8.days.ago)

    perform_with_healthy_disk

    assert_evicted conversation, "ordinary_idle"
  end

  test "leaves an ordinary conversation inside its window alone" do
    conversation = docker_conversation(last_used: 2.days.ago, updated: 2.days.ago)

    perform_with_healthy_disk

    assert_untouched conversation
  end

  test "falls back to updated_at for a legacy docker row without last_used_at" do
    conversation = docker_conversation(last_used: nil, updated: 8.days.ago)

    perform_with_healthy_disk

    assert_evicted conversation, "ordinary_idle"
  end

  test "fresh message activity protects a workspace after the last clean docker run" do
    conversation = docker_conversation(last_used: 30.days.ago, updated: 1.hour.ago)

    perform_with_healthy_disk

    assert_untouched conversation
  end

  test "evicts an archived conversation on the shorter archived window" do
    conversation = docker_conversation(last_used: 2.days.ago, updated: 2.days.ago, archived: 2.days.ago)

    perform_with_healthy_disk

    assert_evicted conversation, "archived_idle"
  end

  test "evicts a terminal workflow's scope after its grace, measured from the later timestamp" do
    conversation = docker_conversation(last_used: 3.days.ago, updated: 3.days.ago)
    run = WorkflowRun.create!(team: @user.personal_team, conversation: conversation, status: :completed)
    run.update_column(:updated_at, 2.days.ago)

    perform_with_healthy_disk

    assert_evicted conversation, "workflow_terminal"
  end

  test "a terminal workflow inside its grace is untouched" do
    conversation = docker_conversation(last_used: 3.days.ago, updated: 3.days.ago)
    run = WorkflowRun.create!(team: @user.personal_team, conversation: conversation, status: :failed)
    run.update_column(:updated_at, 1.hour.ago)

    perform_with_healthy_disk

    assert_untouched conversation
  end

  test "never evicts any active workflow status, even long idle" do
    conversations = WorkflowRun.statuses.keys.select { |s| WorkflowRun.new(status: s).active? }.map do |status|
      conversation = docker_conversation(last_used: 30.days.ago, updated: 30.days.ago)
      WorkflowRun.create!(team: @user.personal_team, conversation: conversation, status: status)
      conversation
    end

    assert_equal 5, conversations.size, "expected the five active statuses"
    perform_with_healthy_disk

    conversations.each { |conversation| assert_untouched conversation }
  end

  test "skips a conversation with an in-flight turn" do
    conversation = docker_conversation(last_used: 8.days.ago, updated: 8.days.ago)
    conversation.messages.create!(role: :assistant, content: "", streaming_status: :streaming)
    conversation.update_column(:updated_at, 8.days.ago)

    perform_with_healthy_disk

    assert_untouched conversation
  end

  test "ignores conversations whose last runtime was not docker" do
    conversation = docker_conversation(last_used: 30.days.ago, updated: 30.days.ago)
    conversation.update_column(:runtime_state, { "runtime" => "local" })

    perform_with_healthy_disk

    assert_untouched conversation
  end

  test "does not re-evict an already-evicted row without a newer docker turn" do
    conversation = docker_conversation(last_used: 8.days.ago, updated: 8.days.ago)
    stamp = 3.days.ago
    conversation.update_columns(docker_workspace_evicted_at: stamp,
                                docker_workspace_eviction_reason: "ordinary_idle")

    perform_with_healthy_disk

    assert_equal stamp.to_i, conversation.reload.docker_workspace_evicted_at.to_i
  end

  test "one failing scope does not stop the batch" do
    bad = docker_conversation(last_used: 8.days.ago, updated: 8.days.ago)
    good = docker_conversation(last_used: 8.days.ago, updated: 8.days.ago)

    failing = ->(conversation) do
      raise Agent::WorkspaceCleanup::UnsafePath, "boom" if conversation.id == bad.id
      Agent::WorkspaceCleanup.new(user_id: conversation.user_id, conversation_id: conversation.id)
    end
    with_stub(Agent::WorkspaceCleanup, :for, failing) do
      EvictDockerWorkspacesJob.perform_now
    end

    assert_evicted good, "ordinary_idle"
    assert_untouched bad
  end

  test "emergency ordering uses the latest clean run or conversation activity" do
    stale_stamp_but_recent = docker_conversation(last_used: 30.days.ago, updated: 1.hour.ago)
    genuinely_old = docker_conversation(last_used: 3.days.ago, updated: 3.days.ago)

    evictions = 0
    space = ->(kb_free) { Agent::WorkspaceCleanup::FreeSpace.new(100, kb_free) }
    with_stub(Agent::WorkspaceCleanup, :free_space, ->(**) { evictions.positive? ? space.call(40) : space.call(10) }) do
      with_stub(Agent::WorkspaceCleanup, :for, ->(conversation) {
        evictions += 1
        Agent::WorkspaceCleanup.new(user_id: conversation.user_id, conversation_id: conversation.id)
      }) do
        EvictDockerWorkspacesJob.perform_now
      end
    end

    assert_evicted genuinely_old, "low_disk"
    assert_untouched stale_stamp_but_recent
  end

  test "emergency eviction reclaims oldest-first until the recovery watermark" do
    older = docker_conversation(last_used: 3.days.ago, updated: 3.days.ago)
    newer = docker_conversation(last_used: 1.day.ago, updated: 1.day.ago)

    # Below low (15) until one eviction lands, then above recovery (25).
    evictions = 0
    space = ->(kb_free) { Agent::WorkspaceCleanup::FreeSpace.new(100, kb_free) }
    with_stub(Agent::WorkspaceCleanup, :free_space, ->(**) { evictions.positive? ? space.call(40) : space.call(10) }) do
      with_stub(Agent::WorkspaceCleanup, :for, ->(conversation) {
        evictions += 1
        Agent::WorkspaceCleanup.new(user_id: conversation.user_id, conversation_id: conversation.id)
      }) do
        EvictDockerWorkspacesJob.perform_now
      end
    end

    assert_evicted older, "low_disk"
    assert_untouched newer
  end

  test "emergency eviction still refuses active work even when exhausting the disk" do
    conversation = docker_conversation(last_used: 30.days.ago, updated: 30.days.ago)
    WorkflowRun.create!(team: @user.personal_team, conversation: conversation, status: :awaiting_approval)

    with_stub(Agent::WorkspaceCleanup, :free_space, ->(**) { Agent::WorkspaceCleanup::FreeSpace.new(100, 5) }) do
      EvictDockerWorkspacesJob.perform_now
    end

    assert_untouched conversation
  end

  test "a failed free-space probe performs no emergency deletion" do
    conversation = docker_conversation(last_used: 2.days.ago, updated: 2.days.ago)

    with_stub(Agent::WorkspaceCleanup, :free_space, ->(**) { nil }) do
      EvictDockerWorkspacesJob.perform_now
    end

    assert_untouched conversation
  end

  test "logs the structured eviction and summary events" do
    docker_conversation(last_used: 8.days.ago, updated: 8.days.ago)

    log = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    begin
      EvictDockerWorkspacesJob.perform_now
    ensure
      Rails.logger = original
    end

    assert_match(/event=docker_workspace_evicted conversation_id=\d+ user_id=#{@user.id} reason=ordinary_idle bytes_reclaimed=\d+/, log.string)
    assert_match(/event=docker_workspace_eviction_summary scopes_scanned=\d+ total_bytes=\d+ scopes_reclaimed=1/, log.string)
  end
end
