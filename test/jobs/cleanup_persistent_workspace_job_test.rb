require "test_helper"

class CleanupPersistentWorkspaceJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "cpw-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @conversation = @user.conversations.create!
    @workspace = Agent::Workspace.persistent(@conversation).ensure!
    @workspace.session_dir.join("t.jsonl").write("session")
    @workspace.workspace_dir.join("wip.txt").write("files")
  end

  teardown do
    FileUtils.rm_rf(Agent::Workspace::PERSISTENT_ROOT.join("u#{@user.id}"))
  end

  test "deletes the complete scope, sessions included" do
    CleanupPersistentWorkspaceJob.perform_now(user_id: @user.id, conversation_id: @conversation.id)

    refute @workspace.scope_dir.exist?
  end

  test "is idempotent — a duplicate run on a missing scope is harmless" do
    2.times do
      CleanupPersistentWorkspaceJob.perform_now(user_id: @user.id, conversation_id: @conversation.id)
    end

    refute @workspace.scope_dir.exist?
  end

  test "logs and never raises on malformed ids, so nothing retries" do
    log = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    begin
      CleanupPersistentWorkspaceJob.perform_now(user_id: 0, conversation_id: "../../etc")
    ensure
      Rails.logger = original
    end

    assert_match(/event=persistent_workspace_destroy_failed/, log.string)
    assert_match(/ArgumentError/, log.string)
  end

  test "destroying a conversation enqueues cleanup with immutable scalar ids after commit" do
    ids = { user_id: @user.id, conversation_id: @conversation.id }

    assert_enqueued_with(job: CleanupPersistentWorkspaceJob, args: [ ids ]) do
      @conversation.destroy!
    end
    assert @workspace.scope_dir.exist?, "the destroy transaction itself must not touch the filesystem"
  end
end
