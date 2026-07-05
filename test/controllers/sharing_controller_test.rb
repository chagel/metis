require "test_helper"

class SharingControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "sharing@example.com", password: "password123")
    @team = @user.personal_team
  end

  def share_conversation(title: "Shared chat", owner: @user, visibility: :team)
    conversation = owner.conversations.create!(title: title, team: @team, visibility: visibility)
    conversation.generate_share_token!
    conversation
  end

  def share_artifact(filename: "data.csv", owner: @user)
    conversation = owner.conversations.create!(title: "T", team: @team)
    message = conversation.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    message.artifacts.attach(io: StringIO.new("col\na\n"), filename: filename, content_type: "text/csv")
    ArtifactShare.share_blob!(blob: message.artifacts.first.blob, message: message, user: owner)
  end

  test "redirects to sign in when not authenticated" do
    get sharing_path
    assert_redirected_to new_user_session_path
  end

  test "no scope tabs on a personal team; ?scope=team falls back to mine" do
    conversation = share_conversation

    sign_in @user
    get sharing_path(scope: "team")

    assert_response :success
    assert_select ".sharing-tabs", false
    assert_select ".sharing-card .sharing-title", text: conversation.display_title
  end

  test "me and team tabs split own shares from teammates' team-visible ones" do
    team = Team.create!(name: "Shared")
    team.memberships.create!(user: @user, role: :owner)
    teammate = User.create!(email: "mate@example.com", password: "password123")
    team.memberships.create!(user: teammate, role: :member)

    mine = @user.conversations.create!(title: "My link", team: team, visibility: :personal)
    mine.generate_share_token!
    theirs = teammate.conversations.create!(title: "Their link", team: team, visibility: :team)
    theirs.generate_share_token!
    their_secret = teammate.conversations.create!(title: "Their secret", team: team, visibility: :personal)
    their_secret.generate_share_token!

    sign_in @user
    post switch_team_path(team)

    get sharing_path
    assert_select ".sharing-tabs .convo-tab.on", text: "Me"
    assert_select ".sharing-card .sharing-title", text: "My link"
    assert_select ".sharing-card .sharing-title", text: "Their link", count: 0

    get sharing_path(scope: "team")
    assert_select ".sharing-tabs .convo-tab.on", text: "Team"
    assert_select ".sharing-card .sharing-title", text: "Their link"
    assert_select ".sharing-card .sharing-title", text: "My link", count: 0
    assert_select ".sharing-card .sharing-title", text: "Their secret", count: 0
    assert_select ".sharing-stop", false
  end

  test "renders a share_token minted without shared_at (rolling-deploy row)" do
    conversation = share_conversation
    conversation.update_column(:shared_at, nil)

    sign_in @user
    get sharing_path

    assert_response :success
    assert_select ".sharing-card .sharing-title", text: "Shared chat"
  end

  test "lists conversations and artifacts in one stream" do
    conversation = share_conversation
    share = share_artifact

    sign_in @user
    get sharing_path

    assert_response :success
    assert_select ".sharing-card .sharing-title", text: "Shared chat"
    assert_select ".sharing-card .sharing-title", text: "data.csv"
    assert_select ".sharing-url[value=?]", shared_conversation_url(token: conversation.share_token)
    assert_select ".sharing-url[value=?]", shared_artifact_url(token: share.token)
    assert_select ".sharing-stop", count: 2
    # The artifact card carries the chat card's type preview; conversations don't.
    assert_select ".sharing-card-preview .art-csv", count: 1
    assert_select ".sharing-card-preview", count: 1
    # Cards click through to their sources.
    assert_select "a.sharing-title[href=?]", conversation_path(conversation)
    assert_select "a.sharing-title[href=?][target=_blank]", artifact_preview_path(share.blob.signed_id)
  end

  test "a conversation card previews the opening exchange" do
    conversation = share_conversation
    conversation.messages.create!(role: :user, content: "How do I deploy?", streaming_status: :done)
    conversation.messages.create!(role: :assistant, content: "Use Kamal.", streaming_status: :done)
    conversation.messages.create!(role: :user, content: "A later message", streaming_status: :done)

    sign_in @user
    get sharing_path

    assert_select ".sharing-card-preview--chat .sharing-chat-line--user", text: "How do I deploy?"
    assert_select ".sharing-card-preview--chat .sharing-chat-line--assistant", text: "Use Kamal."
    assert_select ".sharing-chat-line", count: 2
  end

  test "the kind filter narrows the stream" do
    share_conversation
    share_artifact

    sign_in @user

    get sharing_path(kind: "artifacts")
    assert_select ".sharing-kinds .convo-tab.on", text: "Artifacts"
    assert_select ".sharing-card .sharing-title", text: "data.csv"
    assert_select ".sharing-card .sharing-title", text: "Shared chat", count: 0

    get sharing_path(kind: "chats")
    assert_select ".sharing-card .sharing-title", text: "Shared chat"
    assert_select ".sharing-card .sharing-title", text: "data.csv", count: 0
  end

  test "shows the empty state when the team shares nothing" do
    sign_in @user
    get sharing_path

    assert_response :success
    assert_select ".sharing-empty-title", text: "Nothing shared yet"
    assert_select ".sharing-card", count: 0
  end

  test "does not list another team's shares" do
    other = User.create!(email: "other@example.com", password: "password123")
    other_conversation = other.conversations.create!(title: "Foreign chat")
    other_conversation.generate_share_token!

    sign_in @user
    get sharing_path

    assert_response :success
    refute_match(/Foreign chat/, response.body)
  end

  test "own rows carry a Stop-sharing button" do
    mine = share_conversation(title: "Mine")
    artifact = share_artifact

    sign_in @user
    get sharing_path

    assert_response :success
    assert_select ".sharing-stop", count: 2
    assert_not_nil mine
    assert_not_nil artifact
  end

  test "lights the Sharing nav item and opens with the sidebar collapsed" do
    sign_in @user
    get sharing_path

    assert_select ".sidebar .prnav .prnav-item.on", text: "Sharing"
    assert_select ".app.sidebar-collapsed"
  end
end
