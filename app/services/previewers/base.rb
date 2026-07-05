module Previewers
  # An artifact previewer maps a blob to (a) a small card body shown
  # in the chat and (b) where the "Open" link points. Subclasses
  # declare which blobs they handle and supply the partial / URL
  # pieces — view code stays branch-free.
  class Base
    INLINE_LINE_LIMIT = 10
    INLINE_ROW_LIMIT = 50

    def self.handles?(_blob) = false

    attr_reader :blob

    def initialize(blob)
      @blob = blob
    end

    # Short uppercase label (RB, CSS, HTML, JSON, PNG…) for the type
    # chip. Filename extension wins because content_type detection is
    # noisy for source code.
    def kind_label
      ext = File.extname(blob.filename.to_s).delete_prefix(".")
      return ext.upcase if ext.present? && ext.length <= 5

      "FILE"
    end

    def card_partial = "previewers/fallback_card"

    # Every artifact opens through the preview page — the one surface
    # with the full chrome (share, download, modes). Path helper (not
    # _url) so Turbo broadcasts without a request host render correctly.
    def open_url(routes) = routes.artifact_preview_path(blob.signed_id)

    # Modes the preview page supports. Empty = the page shows the
    # no-preview fallback (download still works). When 2+, the page
    # renders a Source/Preview toggle in the header.
    def preview_modes = []
    def default_mode = preview_modes.first
    def partial_for_mode(_mode) = nil

    # May the public door serve this blob's bytes with an inline
    # disposition? Only types that are inert on our origin — text/html
    # inline would execute there.
    def inline_safe? = false

    # Does the full preview buffer the blob into worker memory? The
    # public page byte-caps those; client-streamed previews (img, PDF
    # iframe) are exempt.
    def buffered_preview? = true

    # Pick the mode a preview page should render for a raw params value.
    # Coerces defensively (a `?mode[]=x` array must not reach Array#to_sym)
    # and falls back to the default so the two public/authed doors can't
    # drift.
    def resolve_mode(requested)
      sym = requested.to_s.presence&.to_sym
      return sym if preview_modes.include?(sym)

      default_mode
    end
  end
end
