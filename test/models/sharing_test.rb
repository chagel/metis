require "test_helper"

class SharingTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "proj@example.com", password: "password123")
    @team = @user.personal_team
  end

  def share_artifact(filename)
    conversation = @user.conversations.create!(title: "T")
    message = conversation.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    message.artifacts.attach(io: StringIO.new(filename), filename: filename, content_type: "text/csv")
    ArtifactShare.share_blob!(blob: message.artifacts.first.blob, message: message, user: @user)
  end

  test "groups shared conversations and artifact shares, newest first" do
    old_share = share_artifact("old.csv")
    old_share.update_column(:created_at, 2.days.ago)
    new_share = share_artifact("new.csv")

    conversation = @user.conversations.create!(title: "C")
    conversation.generate_share_token!
    @user.conversations.create!(title: "unshared")

    sharing = Sharing.for(team: @team, user: @user)

    assert_equal [ conversation ], sharing.conversations
    assert_equal [ new_share, old_share ], sharing.artifact_shares
    assert sharing.any?
  end

  test "orders shared conversations by shared-at, not last activity" do
    older = @user.conversations.create!(title: "older link")
    older.generate_share_token!
    older.update_column(:shared_at, 3.days.ago)
    newer = @user.conversations.create!(title: "newer link")
    newer.generate_share_token!
    # A stale message bump on the older conversation must not reorder it.
    older.update_column(:updated_at, Time.current)

    assert_equal [ newer, older ], Sharing.for(team: @team, user: @user).conversations
  end

  test "hides a teammate's personal conversation even when it is shared publicly" do
    teammate = User.create!(email: "mate@example.com", password: "password123")
    @team.memberships.create!(user: teammate, role: :member)
    personal = teammate.conversations.create!(title: "Private diary", team: @team, visibility: :personal)
    personal.generate_share_token!
    team_visible = teammate.conversations.create!(title: "Team notes", team: @team, visibility: :team)
    team_visible.generate_share_token!

    conversations = Sharing.for(team: @team, user: @user).conversations

    assert_includes conversations, team_visible
    assert_not_includes conversations, personal
  end

  test "is a pure projection — reading writes no state" do
    share_artifact("data.csv")

    assert_no_changes -> { [ ArtifactShare.order(:id).pluck(:updated_at), Conversation.order(:id).pluck(:updated_at) ] } do
      sharing = Sharing.for(team: @team, user: @user)
      sharing.conversations
      sharing.artifact_shares
      sharing.any?
    end
  end

  test "empty team reports none" do
    sharing = Sharing.for(team: @team, user: @user)
    assert_not sharing.any?
    assert_empty sharing.conversations
    assert_empty sharing.artifact_shares
  end
end
