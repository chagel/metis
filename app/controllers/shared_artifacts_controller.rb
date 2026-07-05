# The public door for a shared artifact: token → ArtifactShare → blob,
# never a raw signed id, so a destroyed share is authoritatively dead.
class SharedArtifactsController < ApplicationController
  include ActiveStorage::Streaming

  skip_before_action :authenticate_user!

  layout "preview"

  def show
    set_share
    @previewer = ArtifactPreviewer.for(@blob)
    @mode = @previewer.resolve_mode(params[:mode])
    @partial = @mode && @previewer.partial_for_mode(@mode)
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

  # Inline serving is only for image previews — streaming e.g. text/html
  # inline would execute it on the app's origin.
  def disposition
    return "inline" if params[:disposition] == "inline" && Previewers::Image.handles?(@blob)

    "attachment"
  end
end
