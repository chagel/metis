class ArtifactPreviewsController < ApplicationController
  layout "preview"

  def show
    @blob = ActiveStorage::Blob.find_signed!(params[:signed_id])
    @message = Message.owning_artifact_blob(@blob).first
    raise ActiveRecord::RecordNotFound unless @message&.conversation&.team&.members&.include?(current_user)

    @previewer = ArtifactPreviewer.for(@blob)
    raise ActiveRecord::RecordNotFound if @previewer.preview_modes.empty?

    @mode = resolve_mode
    @partial = @previewer.partial_for_mode(@mode)
  end

  private

  def resolve_mode
    requested = params[:mode]&.to_sym
    return requested if @previewer.preview_modes.include?(requested)

    @previewer.default_mode
  end
end
