require "test_helper"

class Agent::ForkPreparerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "prep@example.com", password: "password123")
    @source = @user.conversations.create!(
      runtime_state: { "runtime" => "local" }, backend_session_id: "sess-src"
    )
    @u1 = @source.messages.create!(role: :user, content: "q1", streaming_status: :done)
    @a1 = @source.messages.create!(role: :assistant, content: "a1", streaming_status: :done)
    @u2 = @source.messages.create!(role: :user, content: "q2", streaming_status: :done)
    @a2 = @source.messages.create!(role: :assistant, content: "a2", streaming_status: :done)

    @src_ws = Agent::Workspace.persistent(@source).ensure!
    write_source_session
    File.write(@src_ws.workspace_dir.join("notes.txt"), "agent file")
  end

  teardown do
    FileUtils.rm_rf(Agent::Workspace::PERSISTENT_ROOT.join("u#{@user.id}"))
  end

  def write_source_session
    entries = [
      { "type" => "session", "id" => "s0" },
      { "type" => "message", "id" => "e_u1", "message" => { "role" => "user", "content" => "q1" } },
      { "type" => "message", "id" => "e_a1", "message" => { "role" => "assistant", "content" => "a1" } },
      { "type" => "message", "id" => "e_u2", "message" => { "role" => "user", "content" => "q2" } },
      { "type" => "message", "id" => "e_a2", "message" => { "role" => "assistant", "content" => "a2" } }
    ]
    File.write(@src_ws.session_dir.join("2026-01-01T00-00-00-000Z_s.jsonl"),
               entries.map(&:to_json).join("\n") + "\n")
  end

  def fork_from(message) = Agent::ConversationForker.new(message, by: @user).call

  test "copies and truncates the source session when forking an earlier turn" do
    fork = fork_from(@a1) # continue from the first answer; drop the second turn
    assert fork.fork_pending?

    Agent::ForkPreparer.prepare(fork)

    ws = Agent::Workspace.persistent(fork)
    file = Agent::SessionTree.active_session_file(ws.session_dir)
    kept = File.readlines(file).map { |line| JSON.parse(line)["id"] }
    assert_equal %w[s0 e_u1 e_a1], kept
    assert_equal "agent file", File.read(ws.workspace_dir.join("notes.txt"))

    fork.reload
    refute fork.fork_pending?
    assert fork.backend_session_id.present?
    refute fork.needs_history_replay?
  end

  test "an assistant fork at the latest turn keeps the whole session (clone)" do
    fork = fork_from(@a2)
    Agent::ForkPreparer.prepare(fork)

    ws = Agent::Workspace.persistent(fork)
    file = Agent::SessionTree.active_session_file(ws.session_dir)
    assert_equal 5, File.readlines(file).size
  end

  test "does not copy the secret .mcp.json into the fork" do
    File.write(@src_ws.workspace_dir.join(Agent::McpConfig::FILENAME), "{}")
    fork = fork_from(@a2)
    Agent::ForkPreparer.prepare(fork)

    ws = Agent::Workspace.persistent(fork)
    refute File.exist?(ws.workspace_dir.join(Agent::McpConfig::FILENAME))
    assert File.exist?(ws.workspace_dir.join("notes.txt"))
  end

  test "is a no-op when the fork owes no session copy" do
    @source.update!(runtime_state: { "runtime" => "e2b" })
    fork = fork_from(@a2) # cloud source → not pending
    refute fork.fork_pending?

    Agent::ForkPreparer.prepare(fork)
    assert_empty Dir.glob(File.join(Agent::Workspace.persistent(fork).session_dir.to_s, "*"))
  end

  test "an evicted source's missing workspace stays missing on the fork" do
    FileUtils.rm_rf(@src_ws.workspace_dir)
    fork = fork_from(@a2)

    Agent::ForkPreparer.prepare(fork)

    ws = Agent::Workspace.persistent(fork)
    refute ws.workspace_dir.exist?, "fork must mirror the evicted state so its first turn warns"
    assert Agent::SessionTree.active_session_file(ws.session_dir)
    assert fork.reload.backend_session_id.present?
  end

  test "a vanished source degrades gracefully instead of crashing the turn" do
    fork = fork_from(@a2)
    @source.destroy # nullifies fork.forked_from_message_id

    assert_nothing_raised { Agent::ForkPreparer.prepare(fork.reload) }
    refute fork.reload.fork_pending?
  end
end
