require "test_helper"

class EvictDockerWorkspacesJobTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "evict-docker@example.com", password: "password123")
    @window = Rails.application.config.x.agent.docker_workspace_eviction_window
  end

  teardown do
    FileUtils.rm_rf(Agent::Workspace::PERSISTENT_ROOT.join("u#{@user.id}"))
  end

  def docker_conversation(idle_for: @window + 1.hour, runtime: "docker")
    conversation = @user.conversations.create!(runtime_state: { "runtime" => runtime })
    workspace = Agent::Workspace.persistent(conversation).ensure!
    File.write(workspace.workspace_dir.join("wip.txt"), "agent file")
    File.write(workspace.session_dir.join("s.jsonl"), "{}")
    conversation.update_columns(updated_at: idle_for.ago)
    conversation
  end

  def workspace_dir(conversation) = Agent::Workspace.persistent(conversation).workspace_dir

  test "evicts an idle docker workspace, keeping sessions" do
    conversation = docker_conversation

    EvictDockerWorkspacesJob.perform_now

    refute Dir.exist?(workspace_dir(conversation))
    assert File.exist?(Agent::Workspace.persistent(conversation).session_dir.join("s.jsonl"))
  end

  test "leaves recently used conversations alone" do
    conversation = docker_conversation(idle_for: 1.hour)

    EvictDockerWorkspacesJob.perform_now

    assert Dir.exist?(workspace_dir(conversation))
  end

  test "only docker-runtime conversations are candidates" do
    conversation = docker_conversation(runtime: "local")

    EvictDockerWorkspacesJob.perform_now

    assert Dir.exist?(workspace_dir(conversation))
  end

  test "an already-evicted scope is skipped" do
    conversation = docker_conversation
    FileUtils.rm_rf(workspace_dir(conversation))

    assert_nothing_raised { EvictDockerWorkspacesJob.perform_now }
    assert File.exist?(Agent::Workspace.persistent(conversation).session_dir.join("s.jsonl"))
  end

  test "skips a conversation with a turn in flight" do
    conversation = docker_conversation
    conversation.messages.create!(role: :assistant, content: "", streaming_status: :pending)
    conversation.update_columns(updated_at: (@window + 1.hour).ago)

    EvictDockerWorkspacesJob.perform_now

    assert Dir.exist?(workspace_dir(conversation))
  end

  test "never evicts an active workflow run, however idle" do
    conversation = docker_conversation
    @user.personal_team.workflow_runs.create!(conversation: conversation, status: :running)

    EvictDockerWorkspacesJob.perform_now

    assert Dir.exist?(workspace_dir(conversation))
  end

  test "a terminal workflow run evicts once the conversation is idle" do
    conversation = docker_conversation
    @user.personal_team.workflow_runs.create!(conversation: conversation, status: :completed)

    EvictDockerWorkspacesJob.perform_now

    refute Dir.exist?(workspace_dir(conversation))
  end

  test "a per-conversation failure does not stop the loop" do
    doomed = docker_conversation
    fine   = docker_conversation

    original = Agent::Workspace.method(:persistent)
    stub = lambda do |conversation|
      raise "boom" if conversation.id == doomed.id

      original.call(conversation)
    end
    with_stub(Agent::Workspace, :persistent, stub) do
      EvictDockerWorkspacesJob.perform_now
    end

    assert Dir.exist?(workspace_dir(doomed))
    refute Dir.exist?(workspace_dir(fine))
  end
end
