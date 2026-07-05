require "test_helper"

class ArtifactPreviewerTest < ActiveSupport::TestCase
  def blob_with(content_type:, filename: "x", byte_size: 100)
    ActiveStorage::Blob.new(content_type: content_type, filename: filename, byte_size: byte_size)
  end

  test "dispatches images to the Image renderer" do
    assert_instance_of Previewers::Image,
                       ArtifactPreviewer.for(blob_with(content_type: "image/png"))
  end

  test "dispatches PDFs to the Pdf renderer" do
    assert_instance_of Previewers::Pdf,
                       ArtifactPreviewer.for(blob_with(content_type: "application/pdf"))
  end

  test "dispatches CSVs to the Csv renderer" do
    assert_instance_of Previewers::Csv,
                       ArtifactPreviewer.for(blob_with(content_type: "text/csv"))
  end

  test "dispatches plain text, markdown, and JSON to the Text renderer" do
    %w[text/plain text/markdown application/json].each do |content_type|
      assert_instance_of Previewers::Text,
                         ArtifactPreviewer.for(blob_with(content_type: content_type)),
                         "expected Text for #{content_type}"
    end
  end

  test "SVG goes to Fallback, not Image — defending against script-in-image" do
    assert_instance_of Previewers::Fallback,
                       ArtifactPreviewer.for(blob_with(content_type: "image/svg+xml"))
  end

  test "unknown types fall through to Fallback" do
    assert_instance_of Previewers::Fallback,
                       ArtifactPreviewer.for(blob_with(content_type: "application/octet-stream"))
  end

  test "every previewer's Open points at the preview page via a path helper" do
    # Turbo broadcasts render outside a request context; *_url helpers
    # fall back to example.org. Paths are host-agnostic.
    routes = Object.new
    def routes.artifact_preview_path(signed_id) = "/artifacts/#{signed_id}/preview"

    [ "image/jpeg", "application/pdf", "application/zip" ].each do |type|
      blob = blob_with(content_type: type)
      blob.define_singleton_method(:signed_id) { "signed" }
      previewer = ArtifactPreviewer.for(blob)
      assert_equal "/artifacts/signed/preview", previewer.open_url(routes)
    end
  end

  test "Image display_path serves the blob small and a bounded variant large" do
    image = Previewers::Image.new(blob_with(content_type: "image/jpeg"))
    routes = Object.new
    def routes.rails_blob_path(blob, **opts) = "/blob/#{blob.filename}"

    assert_equal "/blob/x", image.display_path(routes)
  end

  test "Image and Pdf render on the preview page; only they are inline-safe and uncapped" do
    image = Previewers::Image.new(blob_with(content_type: "image/png"))
    pdf = Previewers::Pdf.new(blob_with(content_type: "application/pdf"))
    text = Previewers::Text.new(blob_with(content_type: "text/plain", filename: "x.txt"))

    assert_equal [ :preview ], image.preview_modes
    assert_equal "previewers/image_full", image.partial_for_mode(:preview)
    assert_equal [ :preview ], pdf.preview_modes
    assert_equal "previewers/pdf_full", pdf.partial_for_mode(:preview)

    assert image.inline_safe?
    assert pdf.inline_safe?
    assert_not text.inline_safe?
    assert_not image.buffered_preview?
    assert_not pdf.buffered_preview?
    assert text.buffered_preview?
  end

  test "Fallback has no preview modes so the page shows the download-only state" do
    fallback = Previewers::Fallback.new(blob_with(content_type: "application/zip"))
    assert_empty fallback.preview_modes
    assert_nil fallback.partial_for_mode(:preview)
    assert_not fallback.inline_safe?
  end

  test "Text head_lines returns UTF-8 even when the blob carries non-ASCII bytes" do
    # blob.open yields a binary Tempfile; without explicit encoding the
    # rows come back ASCII-8BIT and explode when an ERB template tries
    # to concatenate them with UTF-8 markup.
    user = User.create!(email: "enc-text@example.com", password: "password123")
    msg = user.conversations.create!.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    msg.artifacts.attach(io: StringIO.new("héllo wörld\nsecond line\n"), filename: "notes.txt", content_type: "text/plain")

    lines = Previewers::Text.new(msg.artifacts.first.blob).head_lines

    assert_equal Encoding::UTF_8, lines.first.encoding
    assert_equal "héllo wörld\n", lines.first
  end

  test "code files (Ruby, HTML, CSS, SQL, JS) route to the Text renderer by extension" do
    # Marcel often returns application/octet-stream for source code,
    # so the renderer falls back to extension matching.
    %w[task.rb dashboard.html styles.css schema.sql app.ts main.go].each do |filename|
      blob = blob_with(content_type: "application/octet-stream", filename: filename)
      assert_instance_of Previewers::Text, ArtifactPreviewer.for(blob),
                         "expected Text for #{filename}"
    end
  end

  test "kind_label is the uppercase extension" do
    assert_equal "RB", Previewers::Text.new(blob_with(content_type: "text/plain", filename: "task.rb")).kind_label
    assert_equal "PNG", Previewers::Image.new(blob_with(content_type: "image/png", filename: "chart.png")).kind_label
    assert_equal "JSON", Previewers::Text.new(blob_with(content_type: "application/json", filename: "data.json")).kind_label
  end

  test "kind_label falls back to FILE for missing or absurdly long extensions" do
    no_ext = Previewers::Fallback.new(blob_with(content_type: "application/octet-stream", filename: "weirdbin"))
    long_ext = Previewers::Fallback.new(blob_with(content_type: "application/octet-stream", filename: "x.somethingbig"))

    assert_equal "FILE", no_ext.kind_label
    assert_equal "FILE", long_ext.kind_label
  end

  test "Text exposes preview+source modes for markdown and html, source-only for plain code" do
    md = Previewers::Text.new(blob_with(content_type: "text/markdown", filename: "x.md"))
    html = Previewers::Text.new(blob_with(content_type: "text/html", filename: "x.html"))
    rb = Previewers::Text.new(blob_with(content_type: "application/octet-stream", filename: "x.rb"))

    assert_equal %i[preview source], md.preview_modes
    assert_equal :preview, md.default_mode
    assert_equal %i[preview source], html.preview_modes
    assert_equal :preview, html.default_mode
    assert_equal [ :source ], rb.preview_modes
  end

  test "Text routes each mode to the right partial" do
    md = Previewers::Text.new(blob_with(content_type: "text/markdown", filename: "x.md"))
    html = Previewers::Text.new(blob_with(content_type: "text/html", filename: "x.html"))

    assert_equal "previewers/markdown_full", md.partial_for_mode(:preview)
    assert_equal "previewers/text_full", md.partial_for_mode(:source)
    assert_equal "previewers/html_full", html.partial_for_mode(:preview)
    assert_equal "previewers/text_full", html.partial_for_mode(:source)
  end

  test "Csv head_rows returns UTF-8 cells even when the blob carries non-ASCII bytes" do
    user = User.create!(email: "enc-csv@example.com", password: "password123")
    msg = user.conversations.create!.messages.create!(role: :assistant, content: "x", streaming_status: :done)
    msg.artifacts.attach(io: StringIO.new("name,city\nJoão,São Paulo\n"), filename: "data.csv", content_type: "text/csv")

    rows = Previewers::Csv.new(msg.artifacts.first.blob).head_rows

    assert_equal Encoding::UTF_8, rows.last.first.encoding
    assert_equal [ "João", "São Paulo" ], rows.last
  end
end
