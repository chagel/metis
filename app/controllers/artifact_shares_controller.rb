class ArtifactSharesController < ApplicationController
  # Sharing an artifact is an owner action, like sharing the conversation
  # itself: only the person who owns a conversation the blob is an artifact
  # of may mint or revoke its public link (read-only teammates can't).
  def create
    @blob = ActiveStorage::Blob.find_signed!(params[:signed_id])
    message = owned_artifact_message(@blob)
    raise ActiveRecord::RecordNotFound unless message

    @share = ArtifactShare.share_blob!(blob: @blob, message: message, user: current_user)
    respond_with_panel { redirect_to message.conversation }
  end

  def destroy
    # Scope by creator, not current_team: the owner minted it, so revoke
    # works regardless of which team the session is currently viewing.
    # @share stays unset — the re-rendered panel shows the switch off.
    share = ArtifactShare.minted_by(current_user).find(params[:id])
    @blob = share.blob
    share.destroy!
    respond_with_panel { redirect_back fallback_location: sharing_path }
  end

  # Resolves the owner-only share panel for a lazy frame: Turbo broadcasts
  # render viewer-less, so each authed session fetches its own panel —
  # owners get the toggle, everyone else an empty frame.
  def panel
    @blob = ActiveStorage::Blob.find_signed!(params[:signed_id])
    @manageable = owned_artifact_message(@blob).present?
    @share = @manageable ? ArtifactShare.find_by(blob: @blob) : nil
    render layout: false
  end

  private

  # The blob has to be an :artifacts attachment on a Message in a
  # conversation the current user owns — else a leaked signed_id (or a
  # read-only teammate) could publish someone else's file. Ownership must
  # not outlive team membership: an ex-member's conversations keep their
  # team_id, but their sharing rights end with the membership.
  def owned_artifact_message(blob)
    Message.owning_artifact_blob(blob)
           .joins(:conversation)
           .where(conversations: { user_id: current_user.id, team_id: current_user.team_ids })
           .first
  end

  # The artifact card's share panel re-renders over Turbo; the Sharing
  # page revokes with a full-page form and falls back here.
  def respond_with_panel(&html_fallback)
    respond_to do |format|
      format.turbo_stream { render :panel }
      format.html(&html_fallback)
    end
  end
end
