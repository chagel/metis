require "test_helper"
require "turbo/broadcastable/test_helper"

class ConversationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include Turbo::Broadcastable::TestHelper

  setup do
    @user = User.create!(email: "test@example.com", password: "password123")
  end

  test "redirects to sign in when not authenticated" do
    get conversations_path
    assert_redirected_to new_user_session_path
  end

  test "lists conversations for a signed-in user" do
    @user.conversations.create!(title: "Existing")
    sign_in @user
    get conversations_path
    assert_response :success
    assert_select ".sidebar .convo .tt", text: "Existing"
  end

  test "a solo personal conversation shows no avatars in the sidebar or sender row in the chat" do
    conversation = @user.conversations.create!(title: "Just me")
    conversation.messages.create!(role: :user, content: "hi", streaming_status: :done, sender: @user)
    sign_in @user

    get conversation_path(conversation)
    assert_response :success
    assert_select ".sidebar .convo .convo-avatars", count: 0
    assert_select ".msg-sender-avatar", count: 0
  end

  test "under the Me tab a solo shared-team conversation shows no avatar; the Team tab always does" do
    team = Team.create!(name: "Besty")
    @user.memberships.create!(team: team, role: :owner)
    conversation = @user.conversations.create!(team: team, title: "Solo in team", visibility: :team)
    conversation.messages.create!(role: :user, content: "hi", streaming_status: :done, sender: @user)
    sign_in @user
    post switch_team_path(team)

    get conversations_path
    assert_select ".sidebar .convo .convo-avatars", count: 0

    get conversations_path(filter: "team")
    assert_select ".sidebar .convo .convo-avatars", count: 1
  end

  test "a conversation a teammate has spoken in shows avatars and sender rows" do
    teammate = User.create!(email: "mate@example.com", password: "password123")
    conversation = @user.conversations.create!(title: "Us")
    conversation.messages.create!(role: :user, content: "hi", streaming_status: :done, sender: @user)
    conversation.messages.create!(role: :user, content: "yo", streaming_status: :done, sender: teammate)
    sign_in @user

    get conversation_path(conversation)
    assert_response :success
    assert_select ".sidebar .convo .convo-avatars", count: 1
    assert_select ".msg-sender-avatar", count: 2
  end

  test "starting a new chat creates a conversation with the first message" do
    sign_in @user
    assert_difference -> { @user.conversations.count }, 1 do
      assert_enqueued_with(job: ChatJob) do
        post conversations_path,
             params: { content: "first question", provider: "anthropic", model: "claude-opus-4-8" }
      end
    end

    conversation = @user.conversations.last
    assert_redirected_to conversation
    assert_equal "first question", conversation.messages.find_by(role: :user)&.content
    assert conversation.messages.exists?(role: :assistant, streaming_status: :pending)
  end

  test "stores the chosen provider and model on the conversation" do
    seed_catalog_model(provider: "openai", key: "gpt-5.5")
    sign_in @user
    post conversations_path, params: { content: "hi", model: "gpt-5.5" }

    settings = @user.conversations.last.settings
    assert_equal "openai", settings["provider"]
    assert_equal "gpt-5.5", settings["model"]
  end

  test "new conversation starts with a blank title" do
    sign_in @user
    post conversations_path,
         params: { content: "Help me debug a Rails test", provider: "anthropic", model: "claude-opus-4-8" }

    assert_nil @user.conversations.last.title
  end

  test "rejects starting a chat with no message" do
    sign_in @user
    assert_no_difference -> { @user.conversations.count } do
      post conversations_path, params: { content: "   " }
    end
    assert_response :unprocessable_entity
  end

  test "the composer's visibility pick sets the conversation's visibility" do
    sign_in @user
    post conversations_path, params: { content: "hi team", visibility: "team" }
    assert Conversation.order(:id).last.visibility_team?

    post conversations_path, params: { content: "hi me" }
    assert Conversation.order(:id).last.visibility_personal?
  end

  test "toggle_visibility flips team access and is owner-only" do
    conversation = @user.conversations.create!(title: "mine")
    sign_in @user

    patch visibility_conversation_path(conversation), as: :turbo_stream
    assert conversation.reload.visibility_team?
    patch visibility_conversation_path(conversation), as: :turbo_stream
    assert conversation.reload.visibility_personal?

    stranger = User.create!(email: "x-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in stranger
    patch visibility_conversation_path(conversation), as: :turbo_stream
    assert_response :not_found
    assert conversation.reload.visibility_personal?
  end

  test "share mints a token and renders the panel via turbo stream" do
    conversation = @user.conversations.create!(title: "to share")
    sign_in @user

    post share_conversation_path(conversation), as: :turbo_stream
    assert_response :success
    assert conversation.reload.shared?
    assert_match conversation.share_token, @response.body
  end

  test "share is idempotent and keeps the same token" do
    conversation = @user.conversations.create!(title: "stable")
    sign_in @user

    post share_conversation_path(conversation), as: :turbo_stream
    first_token = conversation.reload.share_token
    post share_conversation_path(conversation), as: :turbo_stream
    assert_equal first_token, conversation.reload.share_token
  end

  test "unshare clears the share token" do
    conversation = @user.conversations.create!(title: "revoke me")
    conversation.generate_share_token!
    sign_in @user

    delete share_conversation_path(conversation), as: :turbo_stream
    assert_response :success
    assert_nil conversation.reload.share_token
  end

  test "share is scoped to the current user's conversations" do
    other = User.create!(email: "other@example.com", password: "password123")
    conversation = other.conversations.create!(title: "not mine")
    sign_in @user

    post share_conversation_path(conversation), as: :turbo_stream
    assert_response :not_found
    assert_nil conversation.reload.share_token
  end

  test "sidebar paginates with a sentinel when more pages exist" do
    sign_in @user
    stub_const(ApplicationController, :SIDEBAR_PAGE_SIZE, 2) do
      3.times { |i| @user.conversations.create!(title: "Convo #{i}") }
      get conversations_path
      assert_response :success
      assert_select "nav.convos[data-controller~='infinite-scroll']"
      assert_select "#convos-sentinel[data-infinite-scroll-target='sentinel'][data-url*='page=2']"
      assert_select "#convos-list .convo", count: 2
    end
  end

  test "sidebar omits the sentinel when only one page exists" do
    sign_in @user
    @user.conversations.create!(title: "Only")
    get conversations_path
    assert_response :success
    assert_select "#convos-sentinel", count: 0
  end

  test "endless-scroll turbo_stream returns the next page of conversations" do
    sign_in @user
    stub_const(ApplicationController, :SIDEBAR_PAGE_SIZE, 2) do
      3.times { |i| @user.conversations.create!(title: "Convo #{i}") }
      get conversations_path(page: 2),
          headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      # Append items before the sentinel, then remove it (last page).
      assert_match(/turbo-stream action="before" target="convos-sentinel"/, response.body)
      assert_match(/turbo-stream action="remove" target="convos-sentinel"/, response.body)
      assert_match(/Convo 0/, response.body)
    end
  end

  test "shows a conversation owned by the user" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Mine")
    get conversation_path(conversation)
    assert_response :success
    assert_select "h1 span", text: "Mine"
  end

  test "shows the runtime a conversation ran on in the context meter" do
    sign_in @user
    conversation = @user.conversations.create!(
      title: "Ran", runtime_state: { "runtime" => "e2b", "sandbox_id" => "sbx-7" }
    )
    get conversation_path(conversation)

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(conversation, :context)}", /e2b/i
  end

  test "does not expose another user's conversation" do
    other = User.create!(email: "other@example.com", password: "password123")
    conversation = other.conversations.create!(title: "Secret")
    sign_in @user
    get conversation_path(conversation)
    assert_response :not_found
  end

  test "cancel stamps the conversation so the in-flight turn stops" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Running")
    post cancel_conversation_path(conversation)

    assert_response :no_content
    assert_not_nil conversation.reload.cancel_requested_at
  end

  test "can rename a conversation" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Old Title")
    patch conversation_path(conversation),
          params: { title: "New Title" },
          as: :json

    assert_response :ok
    assert_equal "New Title", conversation.reload.title
  end

  test "cannot rename a conversation to blank" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Keep Me")
    patch conversation_path(conversation),
          params: { title: "   " },
          as: :json

    assert_response :unprocessable_entity
    assert_equal "Keep Me", conversation.reload.title
  end

  test "cannot rename another user's conversation" do
    other = User.create!(email: "rename-other@example.com", password: "password123")
    conversation = other.conversations.create!(title: "Theirs")
    sign_in @user

    patch conversation_path(conversation),
          params: { title: "Mine Now" },
          as: :json

    assert_response :not_found
    assert_equal "Theirs", conversation.reload.title
  end

  # Temporarily override a constant for the duration of the block.
  # Lets us shrink SIDEBAR_PAGE_SIZE so the sentinel tests don't need
  # to create dozens of conversation fixtures.
  def stub_const(mod, name, value)
    original = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, original)
  end

  test "sidebar hides archived conversations" do
    sign_in @user
    @user.conversations.create!(title: "Visible")
    archived = @user.conversations.create!(title: "Hidden")
    archived.archive!

    get conversations_path
    assert_response :success
    assert_select "#convos-list .convo .tt", text: "Visible"
    assert_select "#convos-list .convo .tt", text: "Hidden", count: 0
  end

  test "archive marks a conversation as archived and redirects to root" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Tidy")

    post archive_conversation_path(conversation)

    assert_redirected_to root_path
    assert conversation.reload.archived?
    assert_equal conversation.id, flash[:undo_archive_id]
  end

  test "archive is reversible via unarchive" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Back")
    conversation.archive!

    post unarchive_conversation_path(conversation)

    refute conversation.reload.archived?
    assert_match(/restored/i, flash[:notice])
  end

  test "archived view lists only archived conversations" do
    sign_in @user
    @user.conversations.create!(title: "Live")
    archived = @user.conversations.create!(title: "Done")
    archived.archive!

    get archived_conversations_path

    assert_response :success
    assert_select ".archived-row", count: 1
    assert_select ".archived-row .archived-title", text: "Done"
  end

  test "showing an archived conversation still works (so it can be restored)" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Frozen")
    conversation.archive!

    get conversation_path(conversation)
    assert_response :success
    assert_select ".archived-banner"
    assert_select ".archived-banner-action", text: "Restore"
  end

  test "cannot archive another user's conversation" do
    other = User.create!(email: "archive-other@example.com", password: "password123")
    conversation = other.conversations.create!(title: "Theirs")
    sign_in @user

    post archive_conversation_path(conversation)

    assert_response :not_found
    refute conversation.reload.archived?
  end

  test "cannot cancel another user's conversation" do
    other = User.create!(email: "cancel-other@example.com", password: "password123")
    conversation = other.conversations.create!(title: "Theirs")
    sign_in @user
    post cancel_conversation_path(conversation)

    assert_response :not_found
  end

  test "a personal workspace shows Mine and Starred tabs but not Shared or Archived" do
    sign_in @user
    get conversations_path

    assert_response :success
    assert_select ".convo-tabs a.convo-tab[href=?]", conversations_path(filter: "active"), text: "Me"
    assert_select ".convo-tabs a.convo-tab[href=?]", conversations_path(filter: "starred"), text: "Starred"
    assert_select ".convo-tabs a.convo-tab[href=?]", conversations_path(filter: "team"), count: 0
    assert_select ".convo-tabs a.convo-tab[href=?]", conversations_path(filter: "archived"), count: 0
    assert_select ".convo-tab.on", text: "Me"
  end

  test "a shared team shows the Shared tab" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :owner)
    sign_in @user
    post switch_team_path(team), headers: { "HTTP_REFERER" => root_path }

    get conversations_path
    assert_response :success
    assert_select ".convo-tabs a.convo-tab[href=?]", conversations_path(filter: "team")
    assert_select ".convo-tabs a.convo-tab #team-tab-dot[hidden]"
  end

  test "opening to the team broadcasts the shared-tab dot; a public link does not" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :owner)
    conversation = @user.conversations.create!(team: team, title: "Shareable")
    sign_in @user

    assert_turbo_stream_broadcasts(team, count: 1) do
      patch visibility_conversation_path(conversation), as: :turbo_stream
    end
    assert conversation.reload.visibility_team?

    link_broadcasts = capture_turbo_stream_broadcasts(team) do
      post share_conversation_path(conversation), as: :turbo_stream
    end
    assert_empty link_broadcasts, "a public link should not ping the team"
    assert conversation.reload.shared?
  end

  test "the shared filter lists every member's shared conversations in the team" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :owner)
    teammate = User.create!(email: "mate-#{SecureRandom.hex(4)}@example.com", password: "password123")
    team.memberships.create!(user: teammate, role: :member)

    teammate.conversations.create!(team: team, title: "Teammate shared", visibility: :team)
    teammate.conversations.create!(team: team, title: "Teammate private")
    @user.conversations.create!(team: team, title: "My shared", visibility: :team)
    # A public link alone no longer surfaces a chat to the team.
    linked = teammate.conversations.create!(team: team, title: "Teammate linked")
    linked.generate_share_token!

    sign_in @user
    post switch_team_path(team), headers: { "HTTP_REFERER" => root_path }
    get conversations_path(filter: "team")

    assert_response :success
    assert_select "#convos-list .convo .tt", text: "Teammate shared"
    assert_select "#convos-list .convo .tt", text: "My shared"
    assert_select "#convos-list .convo .tt", text: "Teammate private", count: 0
    assert_select "#convos-list .convo .tt", text: "Teammate linked", count: 0
    assert_select "#convos-list .convo .convo-avatar"
    assert_select ".convo-tab.on", text: "Team"
  end

  test "the shared filter routes every row to the in-app chat view" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :owner)
    teammate = User.create!(email: "mate-#{SecureRandom.hex(4)}@example.com", password: "password123")
    team.memberships.create!(user: teammate, role: :member)
    shared = teammate.conversations.create!(team: team, title: "Theirs", visibility: :team)

    sign_in @user
    post switch_team_path(team), headers: { "HTTP_REFERER" => root_path }
    get conversations_path(filter: "team")

    assert_response :success
    assert_select "#convos-list .convo[href=?][data-turbo-frame=main]", conversation_path(shared)
  end

  test "a team member opens a teammate's shared conversation read-only" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :owner)
    teammate = User.create!(email: "mate-#{SecureRandom.hex(4)}@example.com", password: "password123")
    team.memberships.create!(user: teammate, role: :member)
    shared = teammate.conversations.create!(team: team, title: "Theirs", visibility: :team)
    shared.generate_share_token!
    shared.messages.create!(role: :user, content: "hi")
    shared.messages.create!(
      role: :assistant, content: "the answer", reasoning: "secret thinking",
      streaming_status: :done,
      tool_calls: [ { "name" => "bash", "args" => {}, "output" => "ok", "status" => "done" } ]
    )

    sign_in @user
    post switch_team_path(team), headers: { "HTTP_REFERER" => root_path }
    get conversation_path(shared)

    assert_response :success
    assert_select "h1 span", text: "Theirs"
    assert_select ".readonly-note"
    assert_select "#composer", count: 0
    # The public share link stays available (read-only), but not owner controls.
    assert_select ".chat-actions .share .share-panel-url[value=?]",
                  shared_conversation_url(token: shared.share_token)
    assert_select ".chat-actions .access-switch", count: 0
    assert_select ".chat-actions form[action=?]", archive_conversation_path(shared), count: 0
    # A shared view hides the whole activity block (reasoning + tool calls),
    # like the public share template; the answer text remains.
    assert_select ".activity", count: 0
    assert_select ".reasoning", count: 0
    assert_no_match(/secret thinking/, @response.body)
    assert_select ".chat-content", text: /the answer/
  end

  test "an owner sees reasoning and tool calls in their own conversation" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Mine")
    conversation.messages.create!(
      role: :assistant, content: "answer", reasoning: "my private thinking",
      streaming_status: :done,
      tool_calls: [ { "name" => "bash", "args" => {}, "output" => "ok", "status" => "done" } ]
    )

    get conversation_path(conversation)

    assert_response :success
    assert_select ".activity"
    assert_select ".reasoning", text: "my private thinking"
  end

  test "a team member cannot open a teammate's conversation that is not shared" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :owner)
    teammate = User.create!(email: "mate-#{SecureRandom.hex(4)}@example.com", password: "password123")
    team.memberships.create!(user: teammate, role: :member)
    private_convo = teammate.conversations.create!(team: team, title: "Private")

    sign_in @user
    post switch_team_path(team), headers: { "HTTP_REFERER" => root_path }
    get conversation_path(private_convo)

    assert_response :not_found
  end

  test "the shared filter excludes conversations shared in another team" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :owner)
    other_team = Team.create!(name: "Other")
    stranger = User.create!(email: "str-#{SecureRandom.hex(4)}@example.com", password: "password123")
    other_team.memberships.create!(user: stranger, role: :owner)
    elsewhere = stranger.conversations.create!(team: other_team, title: "Elsewhere")
    elsewhere.generate_share_token!

    sign_in @user
    post switch_team_path(team), headers: { "HTTP_REFERER" => root_path }
    get conversations_path(filter: "team")

    assert_response :success
    assert_select "#convos-list .convo", count: 0
  end

  test "an unknown filter (e.g. archived) falls back to the active scope" do
    sign_in @user
    @user.conversations.create!(title: "Live")
    archived = @user.conversations.create!(title: "Done")
    archived.archive!

    get conversations_path(filter: "archived")

    assert_response :success
    assert_select "#convos-list .convo .tt", text: "Live"
    assert_select "#convos-list .convo .tt", text: "Done", count: 0
    assert_select ".convo-tab.on", text: "Me"
  end

  test "star marks a conversation as starred via turbo stream" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Pin me")

    post star_conversation_path(conversation), as: :turbo_stream

    assert_response :success
    assert conversation.reload.starred?
    assert_select "turbo-stream[action=replace][target=?]", dom_id(conversation, :star)
  end

  test "star is reversible via unstar" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Unpin me")
    conversation.star!

    delete star_conversation_path(conversation), as: :turbo_stream

    assert_response :success
    refute conversation.reload.starred?
  end

  test "cannot star another user's conversation" do
    other = User.create!(email: "star-other@example.com", password: "password123")
    conversation = other.conversations.create!(title: "Theirs")
    sign_in @user

    post star_conversation_path(conversation)

    assert_response :not_found
    refute conversation.reload.starred?
  end

  test "the starred filter lists only the user's active starred conversations" do
    sign_in @user
    @user.conversations.create!(title: "Plain")
    starred = @user.conversations.create!(title: "Important")
    starred.star!
    archived_starred = @user.conversations.create!(title: "Old favourite")
    archived_starred.star!
    archived_starred.archive!

    get conversations_path(filter: "starred")

    assert_response :success
    assert_select "#convos-list .convo .tt", text: "Important"
    assert_select "#convos-list .convo .tt", text: "Plain", count: 0
    assert_select "#convos-list .convo .tt", text: "Old favourite", count: 0
    assert_select ".convo-tab.on", text: "Starred"
  end

  test "the owner sees a star toggle on their own conversation" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Mine")

    get conversation_path(conversation)

    assert_response :success
    assert_select ".chat-actions form[action=?]", star_conversation_path(conversation)
  end
end
