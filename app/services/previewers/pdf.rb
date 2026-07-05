module Previewers
  # Browser-native PDF viewer, embedded in the preview page — no inline
  # body on the card (a PDF thumbnail isn't worth the rendering cost).
  class Pdf < Base
    def self.handles?(blob) = blob.content_type == "application/pdf"

    def preview_modes = [ :preview ]
    def partial_for_mode(_mode) = "previewers/pdf_full"

    def inline_safe? = true
    def buffered_preview? = false

    def display_path(routes)
      routes.rails_blob_path(blob, disposition: "inline")
    end
  end
end
