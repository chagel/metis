require "test_helper"

class ArtifactShareTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "sharer@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "T")
    @message = @conversation.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    @message.artifacts.attach(io: StringIO.new("col\na\n"), filename: "data.csv", content_type: "text/csv")
    @blob = @message.artifacts.first.blob
  end

  test "share_blob! creates one row with a unique token and the resolved team" do
    share = ArtifactShare.share_blob!(blob: @blob, message: @message, user: @user)

    assert_equal @conversation.team, share.team
    assert_equal @user, share.created_by
    assert share.token.present?
  end

  test "share_blob! is idempotent for the same blob" do
    first = ArtifactShare.share_blob!(blob: @blob, message: @message, user: @user)
    second = ArtifactShare.share_blob!(blob: @blob, message: @message, user: @user)

    assert_equal first.id, second.id
    assert_equal 1, ArtifactShare.count
  end

  test "for_blobs keys the strip's lookup by blob id" do
    share = ArtifactShare.share_blob!(blob: @blob, message: @message, user: @user)

    assert_equal [ share ], ArtifactShare.for_blobs([ @blob.id ]).to_a
    assert_empty ArtifactShare.for_blobs([])
  end

  test "the share survives its owning message being destroyed" do
    share = ArtifactShare.share_blob!(blob: @blob, message: @message, user: @user)
    @message.destroy!

    assert ArtifactShare.exists?(share.id)
    assert_equal @blob, share.reload.blob
  end
end
