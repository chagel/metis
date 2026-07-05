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

  test "lists the team's shared conversations and artifacts in two sections" do
    conversation = share_conversation
    share = share_artifact

    sign_in @user
    get sharing_path

    assert_response :success
    assert_select ".sharing-section-title", text: "Shared conversations"
    assert_select ".sharing-section-title", text: "Shared artifacts"
    assert_select ".sharing-row .sharing-title", text: "Shared chat"
    assert_select ".sharing-row .sharing-title", text: "data.csv"
    assert_select ".sharing-url[value=?]", shared_conversation_url(token: conversation.share_token)
    assert_select ".sharing-url[value=?]", shared_artifact_url(token: share.token)
    assert_select ".sharing-stop", count: 2
  end

  test "shows the empty state when the team shares nothing" do
    sign_in @user
    get sharing_path

    assert_response :success
    assert_select ".sharing-empty-title", text: "Nothing shared yet"
    assert_select ".sharing-section", count: 0
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

  test "hides a teammate's personal shared conversation but shows team-visible ones" do
    teammate = User.create!(email: "mate@example.com", password: "password123")
    @team.memberships.create!(user: teammate, role: :member)
    personal = share_conversation(title: "Mate private", owner: teammate, visibility: :personal)
    team_visible = share_conversation(title: "Mate team", owner: teammate, visibility: :team)

    sign_in @user
    get sharing_path

    assert_response :success
    refute_match(/Mate private/, response.body)
    assert_match(/Mate team/, response.body)
    # A teammate's row is visible but not revocable by a non-owner.
    assert_select ".sharing-row", text: /Mate team/ do
      assert_select ".sharing-stop", count: 0
    end
    assert_not_nil personal
  end

  test "only the owner gets a Stop-sharing button on a conversation" do
    teammate = User.create!(email: "mate2@example.com", password: "password123")
    @team.memberships.create!(user: teammate, role: :member)
    mine = share_conversation(title: "Mine", owner: @user)
    theirs = share_conversation(title: "Theirs", owner: teammate)

    sign_in @user
    get sharing_path

    assert_response :success
    # Two rows, but only my own conversation exposes a revoke control.
    assert_select ".sharing-stop", count: 1
    assert_not_nil mine
    assert_not_nil theirs
  end

  test "lights the Sharing nav item" do
    sign_in @user
    get sharing_path

    assert_select ".sidebar .prnav .prnav-item.on", text: "Sharing"
  end
end
