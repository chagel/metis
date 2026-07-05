# The public door for a shared artifact: token → ArtifactShare → blob,
# never a raw signed id, so a destroyed share is authoritatively dead.
class SharedArtifactsController < ApplicationController
  skip_before_action :authenticate_user!

  layout "preview"

  def show
    set_share
    @previewer = ArtifactPreviewer.for(@blob)
    @mode = resolve_mode
    @partial = @mode && @previewer.partial_for_mode(@mode)
  end

  def download
    set_share
    send_data @blob.download, filename: @blob.filename.to_s,
              content_type: @blob.content_type, disposition: disposition
  end

  private

  def set_share
    @share = ArtifactShare.find_by!(token: params[:token])
    @blob = @share.blob
  end

  def resolve_mode
    requested = params[:mode]&.to_sym
    return requested if @previewer.preview_modes.include?(requested)

    @previewer.default_mode
  end

  # Inline serving is only for image previews — streaming e.g. text/html
  # inline would execute it on the app's origin.
  def disposition
    return "inline" if params[:disposition] == "inline" && Previewers::Image.handles?(@blob)

    "attachment"
  end
end
