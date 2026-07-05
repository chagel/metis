module Previewers
  # SVG is intentionally NOT here — it can carry script and must not
  # render inline in the chat's origin (falls through to Fallback).
  class Image < Base
    SUPPORTED = %w[image/png image/jpeg image/gif image/webp].freeze
    VARIANT_THRESHOLD = 2.megabytes

    def self.handles?(blob) = SUPPORTED.include?(blob.content_type)

    def card_partial = "previewers/image_card"

    def preview_modes = [ :preview ]
    def partial_for_mode(_mode) = "previewers/image_full"

    def inline_safe? = true
    def buffered_preview? = false

    # Where the authed preview page's <img> points: a bounded variant
    # for big originals, the blob itself otherwise. The public page
    # overrides this with its token route — never a signed blob URL.
    def display_path(routes)
      if blob.byte_size > VARIANT_THRESHOLD
        routes.rails_representation_path(
          blob.variant(resize_to_limit: [ 2000, 2000 ]).processed
        )
      else
        routes.rails_blob_path(blob, disposition: "inline")
      end
    end
  end
end
