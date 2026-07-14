require "test_helper"

class CleanupPersistentWorkspaceJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "cleanup@example.com", password: "password123")
  end

  teardown do
    FileUtils.rm_rf(Agent::Workspace::PERSISTENT_ROOT.join("u#{@user.id}"))
  end

  test "removes the whole scope, sessions included" do
    conversation = @user.conversations.create!
    workspace = Agent::Workspace.persistent(conversation).ensure!
    File.write(workspace.session_dir.join("s.jsonl"), "{}")

    CleanupPersistentWorkspaceJob.perform_now(user_id: @user.id, conversation_id: conversation.id)

    refute workspace.scope_dir.exist?
  end

  test "destroying a conversation enqueues the cleanup with scalar ids" do
    conversation = @user.conversations.create!

    assert_enqueued_with(
      job: CleanupPersistentWorkspaceJob,
      args: [ { user_id: @user.id, conversation_id: conversation.id } ]
    ) do
      conversation.destroy!
    end
  end
end
