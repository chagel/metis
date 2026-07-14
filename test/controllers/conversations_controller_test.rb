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

  test "the sidebar's query count does not scale with its rows" do
    teammate = User.create!(email: "n1-mate@example.com", password: "password123")
    build_row = lambda do |i|
      conversation = @user.conversations.create!(title: "Row #{i}")
      conversation.messages.create!(role: :user, content: "hi", streaming_status: :done, sender: teammate)
      conversation.messages.create!(role: :assistant, content: "", streaming_status: :streaming)
      @user.personal_team.workflow_runs.create!(conversation: conversation)
      conversation
    end

    build_row.call(0)
    sign_in @user
    get conversations_path
    baseline = count_queries { get conversations_path }

    5.times { |i| build_row.call(i + 1) }
    grown = count_queries { get conversations_path }

    assert_response :success
    assert_select ".sidebar .convo", minimum: 6
    assert_equal baseline, grown, "each sidebar row must not add queries"
  end

  test "a queued workflow run shows a Start pill in the sidebar's needs-you section" do
    conversation = @user.conversations.create!(title: "Queued handoff")
    @user.personal_team.workflow_runs.create!(conversation: conversation, status: :queued)
    sign_in @user

    get conversations_path
    assert_response :success
    assert_select ".convos-pinned .convo .convo-pill--start", text: "Start"
  end

  test "an awaiting-approval workflow run shows a Review pill in the sidebar" do
    conversation = @user.conversations.create!(title: "Gated run")
    @user.personal_team.workflow_runs.create!(conversation: conversation, status: :awaiting_approval)
    sign_in @user

    get conversations_path
    assert_response :success
    assert_select ".convos-pinned .convo .convo-pill", text: "Review"
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

  test "the kind filter narrows the sidebar list to one conversation type" do
    sign_in @user
    @user.conversations.create!(title: "Plain chat")
    workflow = @user.conversations.create!(title: "A workflow")
    @user.personal_team.workflow_runs.create!(conversation: workflow)
    routine = @user.personal_team.routines.create!(
      user: @user, name: "Standup", prompt: "hi", cron: "0 9 * * *", timezone: "UTC"
    )
    @user.conversations.create!(title: "A routine fire", routine: routine)

    get conversations_path(kind: "chats")
    assert_response :success
    assert_select "#convos-list .convo .tt", text: "Plain chat"
    assert_select "#convos-list .convo .tt", text: "A workflow", count: 0
    assert_select "#convos-list .convo .tt", text: "A routine fire", count: 0
    assert_select ".convo-kind-item.is-active", text: /Chats/

    get conversations_path(kind: "routines")
    assert_response :success
    assert_select "#convos-list .convo .tt", text: "A routine fire"
    assert_select "#convos-list .convo .tt", text: "Plain chat", count: 0
  end

  test "an unknown kind param falls back to all" do
    sign_in @user
    @user.conversations.create!(title: "Plain chat")

    get conversations_path(kind: "bogus")

    assert_response :success
    assert_select "#convos-list .convo .tt", text: "Plain chat"
    assert_select ".convo-kind-item.is-active", text: /All/
  end

  test "search requires authentication" do
    get search_conversations_path(q: "deploy")
    assert_redirected_to new_user_session_path
  end

  test "search finds titles beyond the first browse page" do
    needle = @user.conversations.create!(title: "Needle in history")
    needle.update_column(:updated_at, 1.year.ago)
    (ApplicationController::SIDEBAR_PAGE_SIZE + 1).times { |i| @user.conversations.create!(title: "Noise #{i}") }
    sign_in @user

    get conversations_path
    assert_select "#convos-list .convo .tt", text: "Needle in history", count: 0

    get search_conversations_path(q: "needle")
    assert_response :success
    assert_select "turbo-frame#convos-search .convo .tt", text: "Needle in history"
  end

  test "search renders an ungrouped result list without pins or recency headers" do
    pinned = @user.conversations.create!(title: "Needs me now")
    @user.personal_team.workflow_runs.create!(conversation: pinned, status: :queued)
    @user.conversations.create!(title: "Plain match")
    sign_in @user

    get search_conversations_path(q: "match")
    assert_response :success
    assert_select ".grp-label", count: 0
    assert_select ".convos-pinned", count: 0
    assert_select "#convos-sentinel", count: 0
    assert_select ".convo .tt", text: "Plain match"
  end

  test "search below two characters returns no results" do
    @user.conversations.create!(title: "Aha moment")
    sign_in @user

    get search_conversations_path(q: " a ")
    assert_response :success
    assert_select "turbo-frame#convos-search"
    assert_select ".convo", count: 0
    assert_select ".convos-empty", count: 0
  end

  test "search paginates at SEARCH_PAGE_SIZE with a sentinel preserving q, filter, and kind" do
    stub_const(ConversationsController, :SEARCH_PAGE_SIZE, 2) do
      3.times { |i| @user.conversations.create!(title: "Match #{i}") }
      sign_in @user

      get search_conversations_path(q: "match", filter: "starred", kind: "chats")
      assert_response :success
      assert_select "#convos-search-list .convo", count: 0 # starred scope excludes them

      get search_conversations_path(q: "match", kind: "chats")
      assert_select "#convos-search-list .convo", count: 2
      assert_select "#convos-search-sentinel[data-conversation-search-target='sentinel']" do |nodes|
        url = nodes.first["data-url"]
        assert_includes url, "q=match"
        assert_includes url, "kind=chats"
        assert_includes url, "filter=active"
        assert_includes url, "page=2"
      end
    end
  end

  test "search page 2 streams the remaining rows without duplicates and drops the sentinel" do
    stub_const(ConversationsController, :SEARCH_PAGE_SIZE, 2) do
      3.times { |i| @user.conversations.create!(title: "Match #{i}") }
      sign_in @user

      get search_conversations_path(q: "match", page: 2),
          headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert_match(/turbo-stream action="append" target="convos-search-list"/, response.body)
      assert_match(/turbo-stream action="remove" target="convos-search-sentinel"/, response.body)
      assert_match(/Match 0/, response.body)
      assert_no_match(/Match 2/, response.body)
    end
  end

  test "search middle page replaces the sentinel and preserves nondefault filters" do
    stub_const(ConversationsController, :SEARCH_PAGE_SIZE, 2) do
      5.times do |i|
        @user.conversations.create!(title: "Paged match #{i}").star!
      end
      sign_in @user

      get search_conversations_path(q: "paged match", filter: "starred", kind: "chats", page: 2),
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_select "turbo-stream[action='replace'][target='convos-search-sentinel']"
      assert_select "#convos-search-sentinel" do |nodes|
        query = Rack::Utils.parse_query(URI.parse(nodes.first["data-url"]).query)
        assert_equal "paged match", query["q"]
        assert_equal "starred", query["filter"]
        assert_equal "chats", query["kind"]
        assert_equal "3", query["page"]
      end
    end
  end

  test "search under the default scope includes the user's archived matches" do
    archived = @user.conversations.create!(title: "Archived treasure")
    archived.archive!
    sign_in @user

    get search_conversations_path(q: "treasure")
    assert_response :success
    assert_select ".convo .tt", text: "Archived treasure"
    assert_select ".convo-badge-archived", text: "Archived"
  end

  test "search never crosses team or visibility boundaries, even for exact titles" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :owner)
    teammate = User.create!(email: "search-mate@example.com", password: "password123")
    team.memberships.create!(user: teammate, role: :member)

    mine = @user.conversations.create!(team: team, title: "Quarterly plan", visibility: :team)
    my_private = @user.conversations.create!(team: team, title: "Quarterly plan")
    team_visible = teammate.conversations.create!(team: team, title: "Quarterly plan", visibility: :team)
    archived_team_visible = teammate.conversations.create!(team: team, title: "Quarterly plan", visibility: :team)
    archived_team_visible.archive!
    teammate_private = teammate.conversations.create!(team: team, title: "Quarterly plan")
    linked = teammate.conversations.create!(team: team, title: "Quarterly plan")
    linked.generate_share_token!

    other_team = Team.create!(name: "Elsewhere")
    stranger = User.create!(email: "search-stranger@example.com", password: "password123")
    other_team.memberships.create!(user: stranger, role: :owner)
    stranger.conversations.create!(team: other_team, title: "Quarterly plan", visibility: :team)

    sign_in @user
    post switch_team_path(team)

    get search_conversations_path(q: "quarterly", filter: "team")
    assert_response :success
    ids = css_select(".convo").map { |node| node["href"] }
    expected = [ mine, team_visible, archived_team_visible ].map { |c| conversation_path(c) }
    assert_equal expected.sort, ids.sort
    refute_includes ids, conversation_path(teammate_private)
    refute_includes ids, conversation_path(linked)
    refute_includes ids, conversation_path(my_private)

    get search_conversations_path(q: "quarterly", filter: "active")
    assert_equal [ conversation_path(mine), conversation_path(my_private) ].sort,
                 css_select(".convo").map { |node| node["href"] }.sort
  end

  test "search coerces the team filter to active in a personal team" do
    @user.conversations.create!(title: "Personal find", visibility: :team)
    sign_in @user

    get search_conversations_path(q: "personal find", filter: "team")
    assert_response :success
    assert_select ".convo .tt", text: "Personal find"
  end

  test "search under starred includes archived starred matches only" do
    starred = @user.conversations.create!(title: "Gem idea")
    starred.star!
    starred.archive!
    @user.conversations.create!(title: "Gem idea (unstarred)")
    sign_in @user

    get search_conversations_path(q: "gem idea", filter: "starred")
    assert_response :success
    assert_select ".convo", count: 1
    assert_select ".convo-badge-archived"
  end

  test "search falls back to active/all on unknown filter and kind" do
    @user.conversations.create!(title: "Fallback target")
    sign_in @user

    get search_conversations_path(q: "fallback", filter: "bogus", kind: "bogus")
    assert_response :success
    assert_select ".convo .tt", text: "Fallback target"
  end

  test "search honors the kind axis" do
    @user.conversations.create!(title: "Kindred chat")
    workflow = @user.conversations.create!(title: "Kindred workflow")
    @user.personal_team.workflow_runs.create!(conversation: workflow)
    sign_in @user

    get search_conversations_path(q: "kindred", kind: "workflows")
    assert_response :success
    assert_select ".convo", count: 1
    assert_select ".convo .tt", text: "Kindred workflow"
    assert_select ".convo .convo-pill", text: "Workflow"
  end

  test "search rows show meta but no message snippet" do
    project = @user.personal_team.projects.create!(name: "Skunkworks")
    conversation = @user.conversations.create!(title: "Meta rich", project: project)
    conversation.messages.create!(role: :user, content: "secret message body", streaming_status: :done)
    sign_in @user

    get search_conversations_path(q: "meta rich")
    assert_response :success
    assert_select ".convo[data-turbo-frame='main'][href=?]", conversation_path(conversation)
    assert_select ".convo-search-meta", text: /ago/
    assert_select ".convo-search-project", text: "Skunkworks"
    assert_no_match(/secret message body/, response.body)
  end

  test "search shows an empty state with the query" do
    sign_in @user
    get search_conversations_path(q: "zz-nothing")
    assert_response :success
    assert_select ".convos-empty", text: /zz-nothing/
  end

  test "search copy is localized in English and Simplified Chinese" do
    {
      "conversations.sidebar.search" => [ "Search history", "搜索历史" ],
      "conversations.sidebar.search_loading" => [ "Searching history…", "正在搜索历史…" ],
      "conversations.sidebar.search_retry" => [ "Retry", "重试" ],
      "conversations.search_result.archived" => [ "Archived", "已归档" ]
    }.each do |key, (en, zh)|
      assert_equal en, I18n.t(key, locale: :en)
      assert_equal zh, I18n.t(key, locale: :"zh-CN")
    end
    assert_equal "Results for “deploy”",
                 I18n.t("conversations.search.results_for", query: "deploy", locale: :en)
    assert_equal "未找到与“deploy”相关的对话。",
                 I18n.t("conversations.search.empty", query: "deploy", locale: :"zh-CN")
  end

  test "the sidebar wires the search controller and status region" do
    sign_in @user
    get conversations_path

    assert_response :success
    assert_select "#sidebar[data-controller='conversation-search'][data-conversation-search-url-value=?]",
                  search_conversations_path
    assert_select "#sidebar[data-conversation-search-min-length-value=?]",
                  ConversationsController::SEARCH_MIN_LENGTH.to_s
    assert_select ".search input[data-conversation-search-target='input']"
    assert_select ".convos-search .convos-search-summary[aria-live='polite'][data-conversation-search-target='loading']"
    assert_select ".convos-search .convos-search-summary[aria-live='polite'][data-conversation-search-target='error']"
    assert_select ".convos-search turbo-frame#convos-search"
    assert_select ".convo-controls[data-filter='active'][data-kind='all']"
  end

  test "the owner sees a star toggle on their own conversation" do
    sign_in @user
    conversation = @user.conversations.create!(title: "Mine")

    get conversation_path(conversation)

    assert_response :success
    assert_select ".chat-actions form[action=?]", star_conversation_path(conversation)
  end
end
