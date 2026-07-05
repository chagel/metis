class ArtifactPreviewsController < ApplicationController
  layout "preview"

  def show
    @blob = ActiveStorage::Blob.find_signed!(params[:signed_id])
    @message = Message.owning_artifact_blob(@blob).first
    raise ActiveRecord::RecordNotFound unless @message&.conversation&.team&.members&.include?(current_user)

    @previewer = ArtifactPreviewer.for(@blob)
    @mode = @previewer.resolve_mode(params[:mode])
    @partial = @previewer.partial_for_mode(@mode)

    # The share panel lives here, not on the chat's artifact card — this
    # page knows its viewer, so the owner-only gate is a plain check.
    @can_share = Message.owning_artifact_blob(@blob).owned_by(current_user).exists?
    @share = ArtifactShare.find_by(blob: @blob) if @can_share
  end
end
