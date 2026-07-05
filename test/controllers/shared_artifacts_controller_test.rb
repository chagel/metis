require "test_helper"

class SharedArtifactsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "owner@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Secret plans")
    @message = @conversation.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    @message.artifacts.attach(io: StringIO.new("col\na\nb\n"), filename: "data.csv", content_type: "text/csv")
    @blob = @message.artifacts.first.blob
    @share = ArtifactShare.share_blob!(blob: @blob, message: @message, user: @user)
  end

  test "renders the public preview without authentication, file only" do
    get shared_artifact_path(token: @share.token)

    assert_response :success
    assert_select "h1.preview-title", text: "data.csv"
    assert_select "table.preview-csv"
    refute_match(/Secret plans/, response.body)
    assert_select ".preview-back", false
  end

  test "download streams the blob as an attachment" do
    get download_shared_artifact_path(token: @share.token)

    assert_response :success
    assert_match(/attachment/, response.headers["Content-Disposition"])
    assert_equal "col\na\nb\n", response.body
  end

  test "show skips the in-memory preview for blobs over the byte limit" do
    big = @conversation.messages.create!(role: :assistant, content: "y", streaming_status: :done)
    big.artifacts.attach(io: StringIO.new("a" * (SharedArtifactsController::PREVIEW_BYTE_LIMIT + 1)),
                         filename: "huge.txt", content_type: "text/plain")
    share = ArtifactShare.share_blob!(blob: big.artifacts.first.blob, message: big, user: @user)

    get shared_artifact_path(token: share.token)

    assert_response :success
    assert_select ".preview-none"
    assert_select ".preview-download"
  end

  test "404s an unknown token" do
    get shared_artifact_path(token: "no-such-token")
    assert_response :not_found

    get download_shared_artifact_path(token: "no-such-token")
    assert_response :not_found
  end

  test "404s once the share is destroyed" do
    @share.destroy!

    get shared_artifact_path(token: @share.token)
    assert_response :not_found

    get download_shared_artifact_path(token: @share.token)
    assert_response :not_found
  end

  test "an image preview serves inline through the token route, never a signed blob URL" do
    @message.artifacts.attach(
      io: File.open(Rails.root.join("test/fixtures/files/sample.png")),
      filename: "sample.png", content_type: "image/png"
    )
    blob = ActiveStorage::Blob.find_by(filename: "sample.png")
    share = ArtifactShare.share_blob!(blob: blob, message: @message, user: @user)

    get shared_artifact_path(token: share.token)
    assert_response :success
    assert_select "img.preview-image[src=?]",
                  download_shared_artifact_path(token: share.token, disposition: :inline)
    refute_match(/rails\/active_storage/, response.body)

    get download_shared_artifact_path(token: share.token, disposition: :inline)
    assert_match(/inline/, response.headers["Content-Disposition"])
  end

  test "inline disposition is refused for blobs that could execute on our origin" do
    get download_shared_artifact_path(token: @share.token, disposition: :inline)
    assert_match(/attachment/, response.headers["Content-Disposition"])
  end

  test "a PDF renders in the embedded viewer through the token route" do
    @message.artifacts.attach(io: StringIO.new("%PDF-1.4 fake"), filename: "report.pdf",
                              content_type: "application/pdf")
    blob = ActiveStorage::Blob.find_by(filename: "report.pdf")
    share = ArtifactShare.share_blob!(blob: blob, message: @message, user: @user)

    get shared_artifact_path(token: share.token)
    assert_response :success
    assert_select "iframe.preview-pdf[src=?]",
                  download_shared_artifact_path(token: share.token, disposition: :inline)
    refute_match(/rails\/active_storage/, response.body)

    get download_shared_artifact_path(token: share.token, disposition: :inline)
    assert_match(/inline/, response.headers["Content-Disposition"])
  end

  test "a mode-less renderer still gets a page with a working download" do
    @message.artifacts.attach(io: StringIO.new("\x00\x01binary"), filename: "data.bin",
                              content_type: "application/octet-stream")
    blob = ActiveStorage::Blob.find_by(filename: "data.bin")
    share = ArtifactShare.share_blob!(blob: blob, message: @message, user: @user)

    get shared_artifact_path(token: share.token)
    assert_response :success
    assert_select "p.preview-none"
    assert_select "a.preview-download[href=?]", download_shared_artifact_path(token: share.token)
  end
end
