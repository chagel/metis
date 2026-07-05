require "test_helper"

class SharingControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "sharing@example.com", password: "password123")
    @team = @user.personal_team
  end

  def share_conversation(title: "Shared chat")
    conversation = @user.conversations.create!(title: title)
    conversation.generate_share_token!
    conversation
  end

  def share_artifact(filename: "data.csv")
    conversation = @user.conversations.create!(title: "T")
    message = conversation.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    message.artifacts.attach(io: StringIO.new("col\na\n"), filename: filename, content_type: "text/csv")
    ArtifactShare.share_blob!(blob: message.artifacts.first.blob, message: message, user: @user)
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

  test "lights the Sharing nav item" do
    sign_in @user
    get sharing_path

    assert_select ".sidebar .prnav .prnav-item.on", text: "Sharing"
  end
end
