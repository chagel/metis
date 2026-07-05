class ArtifactSharesController < ApplicationController
  def create
    @blob = ActiveStorage::Blob.find_signed!(params[:signed_id])
    message = Message.owning_artifact_blob(@blob).first
    raise ActiveRecord::RecordNotFound unless message&.conversation&.team&.members&.include?(current_user)

    ArtifactShare.share_blob!(blob: @blob, message: message, user: current_user)
    respond_with_panel { redirect_to message.conversation }
  end

  def destroy
    share = ArtifactShare.where(team: current_team).find(params[:id])
    @blob = share.blob
    share.destroy!
    respond_with_panel { redirect_back fallback_location: sharing_path }
  end

  private

  # The artifact card's share panel re-renders over Turbo; the Sharing
  # page revokes with a full-page form and falls back here.
  def respond_with_panel(&html_fallback)
    respond_to do |format|
      format.turbo_stream { render :panel }
      format.html(&html_fallback)
    end
  end
end
