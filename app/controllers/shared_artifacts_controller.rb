# The public door for a shared artifact: token → ArtifactShare → blob,
# never a raw signed id, so a destroyed share is authoritatively dead.
class SharedArtifactsController < ApplicationController
  include ActiveStorage::Streaming

  skip_before_action :authenticate_user!

  layout "preview"

  # Buffered previews load the blob into worker memory (Text#full_content,
  # Csv#all_rows), so this unauthenticated door only renders them for small
  # files — bigger ones fall through to the streamed download. Client-
  # streamed previews (img, PDF iframe) are exempt.
  PREVIEW_BYTE_LIMIT = 2.megabytes

  def show
    set_share
    @previewer = ArtifactPreviewer.for(@blob)
    @mode = @previewer.resolve_mode(params[:mode])
    @partial = (@previewer.partial_for_mode(@mode) if @mode && previewable?)
  end

  # Stream in chunks rather than buffering the whole blob in worker memory
  # (this endpoint is unauthenticated and has no artifact size cap). The
  # token gate still decides access, so revocation stays authoritative.
  def download
    set_share
    send_blob_stream @blob, disposition: disposition
  end

  private

  def set_share
    @share = ArtifactShare.find_by!(token: params[:token])
    @blob = @share.blob
  end

  def previewable?
    !@previewer.buffered_preview? || @blob.byte_size <= PREVIEW_BYTE_LIMIT
  end

  # Inline serving only for types the previewer declares inert on our
  # origin — streaming e.g. text/html inline would execute it here.
  def disposition
    return "inline" if params[:disposition] == "inline" && ArtifactPreviewer.for(@blob).inline_safe?

    "attachment"
  end
end
