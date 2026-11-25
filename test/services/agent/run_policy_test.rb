require "test_helper"

class Agent::RunPolicyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "policy-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @github = @team.connectors.create!(name: "github", transport: :http, catalog_key: "github",
                                       definition: { "url" => "https://mcp.example/" }, bot_enabled: true)
    @linear = @team.connectors.create!(name: "linear", transport: :http, definition: { "url" => "https://linear.example/" })
  end

  teardown do
    FileUtils.rm_rf(Agent::Workspace::PERSISTENT_ROOT.join("u#{@user.id}"))
  end

  def routine(grants: {})
    @team.routines.create!(user: @user, name: "R#{SecureRandom.hex(2)}", prompt: "Go", cron: "0 9 * * *",
                           trigger_config: { "grants" => grants })
  end

  def fired(grants: {}) = routine(grants: grants).fire!

  def servers(conversation) = JSON.parse(Agent::McpConfig.new(conversation).content)["mcpServers"]

  def with_bot(&block)
    with_stub(GithubApp::Config, :app_auth_configured?, -> { true }) do
      with_stub(GithubApp::InstallationToken, :for, ->(_id = nil) { "ghs_bot" }, &block)
    end
  end

  test "a chat turn is attended and reaches everything" do
    conversation = @user.conversations.create!
    ConversationTurn.start(conversation, content: "hi", sender: @user)
    policy = Agent::RunPolicy.for(conversation)

    assert_not policy.unattended?
    assert policy.connector_allowed?(@linear)
    assert policy.op_allowed?("create_routine")
  end

  test "a routine fire is unattended; a human reply in it is attended" do
    conversation = fired
    assert Agent::RunPolicy.for(conversation).unattended?

    conversation.messages.where(role: :assistant).update_all(streaming_status: Message.streaming_statuses[:done])
    ConversationTurn.start(conversation, content: "follow up", sender: @user)
    assert_not Agent::RunPolicy.for(conversation).unattended?
  end

  test "an unattended turn stages only granted connectors" do
    assert_equal %w[linear], servers(fired(grants: { "connectors" => %w[linear] })).keys
    assert_empty servers(fired)
  end

  test "an unattended turn gets the bot only when granted" do
    with_bot do
      assert_not servers(fired(grants: { "connectors" => %w[provider:github] })).key?("github_bot")
      assert servers(fired(grants: { "connectors" => %w[github_bot] })).key?("github_bot")
    end
  end

  test "GH_TOKEN reaches an unattended sandbox only with a github connector granted" do
    @user.oauth_grants.create!(provider: "github", access_token: "live-bearer", refresh_token: "rt",
                               expires_at: 1.hour.from_now, scopes: "user:email repo")

    assert_nil Agent::Runtime::Docker.new(conversation: fired).sandbox_env["GH_TOKEN"]
    granted = fired(grants: { "connectors" => %w[provider:github] })
    assert_equal "live-bearer", Agent::Runtime::Docker.new(conversation: granted).sandbox_env["GH_TOKEN"]
  end

  test "Google connectors are one grant that also carries the Google token" do
    %w[gmail google_calendar].each { |key| @team.connectors.create!(name: key, transport: :cli, catalog_key: key) }
    routine = routine(grants: { "connectors" => %w[provider:google] })

    assert_equal "provider:google", routine.grantable_connectors["Google (Gmail, Calendar)"]
    policy = Agent::RunPolicy.for(routine.fire!)
    assert policy.provider_allowed?("google")
    assert policy.connector_allowed?(@team.connectors.find_by(name: "gmail"))
    assert_not policy.provider_allowed?("github")
  end

  test "an unattended turn can't widen itself through HostBridge" do
    conversation = fired
    %w[create_routine update_routine create_workflow update_workflow create_skill update_skill start_workflow].each do |op|
      result = JSON.parse(Agent::HostBridge.call(conversation, op, {}))
      assert_equal false, result["ok"], op
      assert_match "unattended", result["error"]
      assert_not Agent::RunPolicy.for(conversation).op_allowed?("some_future_op")
  end
    assert_not Agent::RunPolicy.for(conversation).op_allowed?("some_future_op")
  end

  test "fails closed when the policy can't be established" do
    conversation = fired(grants: { "connectors" => %w[linear] })
    with_stub(Agent::RunPolicy, :for, ->(_) { raise ActiveRecord::ConnectionNotEstablished }) do
      assert_raises(ActiveRecord::ConnectionNotEstablished) { Agent::McpConfig.new(conversation).content }
      assert_nil Agent::HostBridge.call(conversation, "remember", {})
    end
  end

  test "starting a workflow follows the routine's grant" do
    assert Agent::RunPolicy.for(fired(grants: { "actions" => %w[start_workflow] })).op_allowed?("start_workflow")
  end

  test "only the memory review writes memories unattended" do
    policy = Agent::RunPolicy.for(fired)
    %w[remember update_memory forget_memory].each { |op| assert_not policy.op_allowed?(op), op }
    assert policy.op_allowed?("memory_report")
    assert policy.op_allowed?("note_memory_applied")

    review = MemoryReview.ensure_for(@user, @team).fire!
    assert Agent::RunPolicy.for(review).op_allowed?("remember")
  end

  test "the identity explains the limits and marks ungranted connectors omitted" do
    conversation = fired(grants: { "connectors" => %w[github] })
    content = Agent::Identity.new(conversation, :docker).content

    assert_match "## Unattended run", content
    assert_match "(`linear`) — not granted to this unattended run — omitted", content
    assert_no_match "## Unattended run", Agent::Identity.new(@user.conversations.create!, :docker).content
  end

  test "a fire stays unattended with nothing granted after its routine is deleted" do
    conversation = fired(grants: { "connectors" => %w[linear], "actions" => %w[start_workflow] })
    conversation.routine.destroy!
    policy = Agent::RunPolicy.for(conversation.reload)

    assert policy.unattended?
    assert_empty servers(conversation)
    assert_not policy.op_allowed?("start_workflow")
  end

  test "an unattended turn doesn't sync skills written to disk" do
    assert_not Agent::Runtime::Local.new(conversation: fired).send(:skill_sync_allowed?)

    chat = @user.conversations.create!
    ConversationTurn.start(chat, content: "hi", sender: @user)
    assert Agent::Runtime::Local.new(conversation: chat).send(:skill_sync_allowed?)
  end
end
