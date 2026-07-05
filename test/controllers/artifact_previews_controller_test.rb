require "test_helper"

class ArtifactPreviewsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "owner@example.com", password: "password123")
    @stranger = User.create!(email: "stranger@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "T")
    @message = @conversation.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    @message.artifacts.attach(
      io: StringIO.new("col\na\nb\n"),
      filename: "data.csv",
      content_type: "text/csv"
    )
    @blob = @message.artifacts.first.blob
  end

  test "renders the preview for a member of the conversation's team" do
    sign_in @user
    get artifact_preview_path(@blob.signed_id)

    assert_response :success
    assert_select "table.preview-csv"
    assert_match(/data\.csv/, response.body)
  end

  test "shows the header share button and popover to the conversation owner" do
    sign_in @user
    get artifact_preview_path(@blob.signed_id)

    assert_select ".preview-header .preview-share-btn"
    assert_select ".share .share-panel .access-switch:not(.on)"

    ArtifactShare.share_blob!(blob: @blob, message: @message, user: @user)
    get artifact_preview_path(@blob.signed_id)
    assert_select ".share .share-panel .access-switch.on"
    assert_select ".share .share-panel-url"
  end

  test "hides the share panel from a teammate who is not the owner" do
    team = Team.create!(name: "Shared")
    team.memberships.create!(user: @user, role: :owner)
    teammate = User.create!(email: "mate@example.com", password: "password123")
    team.memberships.create!(user: teammate, role: :member)
    conversation = @user.conversations.create!(title: "Team chat", team: team, visibility: :team)
    msg = conversation.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    msg.artifacts.attach(io: StringIO.new("col\na\n"), filename: "shared.csv", content_type: "text/csv")

    sign_in teammate
    get artifact_preview_path(msg.artifacts.first.blob.signed_id)

    assert_response :success
    assert_select ".preview-share", false
  end

  test "404s a stranger even with a valid signed_id" do
    sign_in @stranger
    get artifact_preview_path(@blob.signed_id)
    assert_response :not_found
  end

  test "404s a blob that isn't attached as an artifact (e.g. a user upload)" do
    # A leaked signed_id for the inbound :files attachment must NOT
    # resolve through this route — only outbound artifacts do.
    user_msg = @conversation.messages.create!(role: :user, content: "u", streaming_status: :done)
    user_msg.files.attach(io: StringIO.new("oops"), filename: "secret.txt", content_type: "text/plain")
    upload_blob = user_msg.files.first.blob

    sign_in @user
    get artifact_preview_path(upload_blob.signed_id)
    assert_response :not_found
  end

  test "redirects to sign-in when not authenticated" do
    get artifact_preview_path(@blob.signed_id)
    assert_redirected_to new_user_session_path
  end

  test "renders the markdown preview by default; ?mode=source switches to raw" do
    @message.artifacts.attach(
      io: StringIO.new("# Heading\n\nbody **bold**\n"),
      filename: "notes.md", content_type: "text/markdown"
    )
    md_blob = ActiveStorage::Blob.find_by(filename: "notes.md")

    sign_in @user
    get artifact_preview_path(md_blob.signed_id)
    assert_select "article.preview-markdown h1", text: "Heading"

    get artifact_preview_path(md_blob.signed_id, mode: :source)
    assert_select "pre.preview-text", text: /# Heading/
  end

  test "renders the HTML preview by default in a sandboxed iframe; ?mode=source shows raw" do
    @message.artifacts.attach(
      io: StringIO.new("<h1>Hi</h1>"),
      filename: "page.html", content_type: "text/html"
    )
    html_blob = ActiveStorage::Blob.find_by(filename: "page.html")

    sign_in @user
    get artifact_preview_path(html_blob.signed_id)
    assert_select "iframe.preview-html"
    assert_match(/<iframe[^>]*\bsandbox="allow-scripts"/, response.body,
                 "sandbox must be present with allow-scripts but nothing else")
    refute_match(/sandbox="[^"]*allow-same-origin/, response.body,
                 "allow-same-origin alongside allow-scripts is equivalent to no sandbox — never add it")
    assert_select "button.preview-fs", text: "Fullscreen"

    get artifact_preview_path(html_blob.signed_id, mode: :source)
    assert_select "pre.preview-text", text: /<h1>Hi<\/h1>/
  end

  test "Fullscreen button does not appear in non-HTML previews" do
    sign_in @user
    get artifact_preview_path(@blob.signed_id)  # the CSV blob from setup
    assert_select "button.preview-fs", false
  end

  test "an invalid ?mode= falls back to the renderer's default" do
    sign_in @user
    get artifact_preview_path(@blob.signed_id, mode: "nope")
    assert_response :success
    assert_select "table.preview-csv"
  end

  test "renders PDFs in the browser-native viewer iframe" do
    @message.artifacts.attach(
      io: StringIO.new("%PDF-1.4 fake"),
      filename: "report.pdf",
      content_type: "application/pdf"
    )
    pdf_blob = @message.artifacts.where(name: "artifacts")
                       .joins(:blob).find_by(active_storage_blobs: { filename: "report.pdf" }).blob

    sign_in @user
    get artifact_preview_path(pdf_blob.signed_id)

    assert_response :success
    assert_select "iframe.preview-pdf"
  end

  test "renders images on the preview page with the full chrome" do
    @message.artifacts.attach(
      io: File.open(Rails.root.join("test/fixtures/files/sample.png")),
      filename: "sample.png", content_type: "image/png"
    )
    png_blob = ActiveStorage::Blob.find_by(filename: "sample.png")

    sign_in @user
    get artifact_preview_path(png_blob.signed_id)

    assert_response :success
    assert_select "img.preview-image"
    assert_select ".preview-share-btn"
  end

  test "a renderer with no preview modes gets the download-only page, not a 404" do
    @message.artifacts.attach(
      io: StringIO.new("\x00\x01binary"),
      filename: "data.bin", content_type: "application/octet-stream"
    )
    bin_blob = ActiveStorage::Blob.find_by(filename: "data.bin")

    sign_in @user
    get artifact_preview_path(bin_blob.signed_id)

    assert_response :success
    assert_select "p.preview-none"
    assert_select ".preview-share-btn"
  end
end
