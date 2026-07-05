require "test_helper"

class ArtifactSharesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "owner@example.com", password: "password123")
    @stranger = User.create!(email: "stranger@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "T")
    @message = @conversation.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    @message.artifacts.attach(io: StringIO.new("col\na\n"), filename: "data.csv", content_type: "text/csv")
    @blob = @message.artifacts.first.blob
  end

  test "create shares the blob and re-renders the panel switched on with the public URL" do
    sign_in @user
    post artifact_shares_path(format: :turbo_stream), params: { signed_id: @blob.signed_id }

    assert_response :success
    share = ArtifactShare.find_by(blob: @blob)
    assert share.present?
    assert_match(/access-switch on/, response.body)
    assert_match %r{/share/artifacts/#{share.token}}, response.body
  end

  test "a second create for the same blob reuses the existing share" do
    sign_in @user
    2.times { post artifact_shares_path(format: :turbo_stream), params: { signed_id: @blob.signed_id } }

    assert_equal 1, ArtifactShare.count
  end

  test "create 404s for a signed_id that is not an artifact attachment" do
    user_msg = @conversation.messages.create!(role: :user, content: "u", streaming_status: :done)
    user_msg.files.attach(io: StringIO.new("oops"), filename: "secret.txt", content_type: "text/plain")

    sign_in @user
    post artifact_shares_path(format: :turbo_stream), params: { signed_id: user_msg.files.first.blob.signed_id }

    assert_response :not_found
    assert_equal 0, ArtifactShare.count
  end

  test "create 404s a stranger even with a valid signed_id" do
    sign_in @stranger
    post artifact_shares_path(format: :turbo_stream), params: { signed_id: @blob.signed_id }

    assert_response :not_found
    assert_equal 0, ArtifactShare.count
  end

  test "create 404s a read-only teammate viewing the owner's team-visible conversation" do
    teammate = in_shared_team_view

    sign_in teammate
    post switch_team_path(@shared_team)
    post artifact_shares_path(format: :turbo_stream), params: { signed_id: @team_blob.signed_id }

    assert_response :not_found
    assert_equal 0, ArtifactShare.count
  end

  test "create 404s an ex-member even for conversations they authored" do
    team = Team.create!(name: "Left behind")
    team.memberships.create!(user: @user, role: :member)
    conversation = @user.conversations.create!(title: "T", team: team, visibility: :team)
    message = conversation.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    message.artifacts.attach(io: StringIO.new("d"), filename: "d.csv", content_type: "text/csv")
    blob = message.artifacts.first.blob
    team.memberships.find_by(user: @user).destroy!

    sign_in @user
    post artifact_shares_path(format: :turbo_stream), params: { signed_id: blob.signed_id }

    assert_response :not_found
    assert_equal 0, ArtifactShare.count
  end

  test "destroy revokes the share and re-renders the panel switched off" do
    share = ArtifactShare.share_blob!(blob: @blob, message: @message, user: @user)

    sign_in @user
    delete artifact_share_path(share, format: :turbo_stream)

    assert_response :success
    assert_not ArtifactShare.exists?(share.id)
    refute_match(/access-switch on/, response.body)
    refute_match(/share-panel-url/, response.body)
  end

  test "destroy 404s anyone who did not create the share" do
    share = ArtifactShare.share_blob!(blob: @blob, message: @message, user: @user)
    teammate = User.create!(email: "mate2@example.com", password: "password123")

    sign_in teammate
    delete artifact_share_path(share, format: :turbo_stream)

    assert_response :not_found
    assert ArtifactShare.exists?(share.id)
  end

  test "requires authentication" do
    post artifact_shares_path, params: { signed_id: @blob.signed_id }
    assert_redirected_to new_user_session_path
  end

  test "the artifact card carries no share panel — sharing lives on the preview page" do
    sign_in @user
    get conversation_path(@conversation)

    assert_select ".art-card"
    assert_select ".art-share", false
  end

  # A team-visible conversation the owner and a member both belong to, with
  # one artifact — the setup for read-only teammate checks.
  def in_shared_team_view
    @shared_team = Team.create!(name: "Shared")
    @user.memberships.create!(team: @shared_team, role: :owner)
    teammate = User.create!(email: "mate@example.com", password: "password123")
    @shared_team.memberships.create!(user: teammate, role: :member)
    @team_conversation = @user.conversations.create!(title: "Team chat", team: @shared_team, visibility: :team)
    msg = @team_conversation.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    msg.artifacts.attach(io: StringIO.new("col\na\n"), filename: "shared.csv", content_type: "text/csv")
    @team_blob = msg.artifacts.first.blob
    teammate
  end

  test "the artifact card hides the share panel on the public conversation page" do
    token = @conversation.generate_share_token!
    get shared_conversation_path(token: token)

    assert_select ".art-card"
    assert_select ".art-share", false
  end
end
