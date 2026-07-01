require "test_helper"

class SharedConversationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "owner@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Shared chat")
    @conversation.messages.create!(role: :user, content: "hello", streaming_status: :done)
    @conversation.messages.create!(role: :assistant, content: "hi back", streaming_status: :done)
    @token = @conversation.generate_share_token!
  end

  test "renders the public conversation without authentication" do
    get shared_conversation_path(token: @token)
    assert_response :success
    assert_select "h1.shared-title", text: "Shared chat"
    assert_select ".thread .chat-content", text: /hello/
    assert_select ".thread .chat-content", text: /hi back/
  end

  test "shows each user message's sender on the public page" do
    teammate = User.create!(email: "teammate@example.com", password: "password123",
                            display_name: "Tea M. Mate")
    @conversation.messages.where(role: :user).first.update!(sender: teammate)

    get shared_conversation_path(token: @token)
    assert_response :success
    assert_select ".msg-user .msg-sender-avatar", count: 1
    assert_select ".msg-user .msg-stamp", text: /Tea M\. Mate/
  end

  test "shows workflow tags when a run drives the conversation" do
    workflow = @user.personal_team.workflows.create!(name: "Ship", steps: [ { "name" => "spec", "prompt" => "p" } ])
    run = @user.personal_team.workflow_runs.create!(conversation: @conversation, workflow: workflow, status: :completed)
    run.tasks.create!(position: 0, name: "spec", prompt: "p", status: :completed)

    get shared_conversation_path(token: @token)
    assert_response :success
    assert_select ".shared-head .wf-meta-name", text: /Ship/
    assert_select ".shared-head .wf-meta-state", text: "Completed"
    assert_select ".wf-rail", count: 0
  end

  test "the assistant caption shows model and duration below the card, not private cost/token meta" do
    provider = LlmProvider.create!(key: "anthropic", label: "Anthropic")
    provider.llm_models.create!(key: "claude-opus-4-8", label: "Claude Opus 4.8")
    @conversation.messages.where(role: :assistant).first.update!(
      model_key: "claude-opus-4-8", input_tokens: 13_200, output_tokens: 2_800, cost: 0.009,
      started_at: Time.current - 70, finished_at: Time.current
    )

    get shared_conversation_path(token: @token)
    assert_response :success
    # Same in-card footer as the interactive chat, reading "model · duration".
    assert_select ".msg-row .ai-card .msg-foot .msg-meta", text: "Claude Opus 4.8 · 1m 10s"
    # No operational meta (tokens/cost) leaks on the public page.
    assert_select ".msg-row", text: /\$/, count: 0
    assert_select ".msg-row", text: /cached/, count: 0
  end

  test "emits Open Graph and Twitter card meta for unfurls" do
    get shared_conversation_path(token: @token)
    assert_response :success

    assert_select "meta[property='og:title'][content=?]", "Shared chat"
    assert_select "meta[property='og:type'][content=?]", "article"
    assert_select "meta[property='og:site_name'][content=?]", "Metis"
    assert_select "meta[property='og:image']" do |tags|
      assert_match %r{og-default.*\.png\z}, tags.first["content"]
      assert_match %r{\Ahttps?://}, tags.first["content"]
    end
    assert_select "meta[property='og:description'][content=?]", "hello"
    assert_select "meta[name='twitter:card'][content=?]", "summary_large_image"
    assert_select "meta[name='twitter:image']"
    assert_select "link[rel='canonical']"
  end

  test "returns 404 for an unknown token" do
    get shared_conversation_path(token: "no-such-token")
    assert_response :not_found
  end

  test "returns 404 once the share has been revoked" do
    @conversation.revoke_share!
    get shared_conversation_path(token: @token)
    assert_response :not_found
  end
end
