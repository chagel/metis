class ConversationsController < ApplicationController
  include Composing

  layout "chat"

  before_action :set_conversation, only: %i[cancel archive unarchive star unstar update share unshare toggle_visibility]
  before_action :set_sidebar, only: %i[index show archived]

  def index
    respond_to do |format|
      format.html
      # Gated on :page so Turbo Drive form redirects don't get the scroll stream.
      format.turbo_stream if params[:page].present?
    end
  end

  def create
    content = composed_content
    uploads = composed_uploads

    if content.blank? && uploads.empty?
      return render_composer_error(nil, "Type a message to start a conversation.")
    end
    if (error = upload_error(uploads))
      return render_composer_error(nil, error)
    end

    conversation = current_user.conversations.create!(
      team: current_team, settings: chat_settings, visibility: composed_visibility
    )
    start_turn(conversation, content, uploads)
    redirect_to conversation
  end

  # Own conversations open normally; a teammate's team-visible conversation
  # opens read-only (same chat view, no composer). The public share link is
  # a separate door (shared_conversations#show). Mutating actions still go
  # through the owner-scoped set_conversation, so read-only here can't be
  # escalated.
  # A workflow-run conversation opens on the run timeline by default;
  # ?view=chat swaps in the raw chat.
  def show
    @conversation = current_user.conversations.find_by(id: params[:id]) ||
                    current_team.conversations.visibility_team.find(params[:id])
    @read_only = @conversation.user_id != current_user.id
    @workflow_run = @conversation.workflow_run
    return render :run if @workflow_run && params[:view] != "chat"

    @messages = @conversation.messages.includes(:sender).chronological
  end

  # PATCH /conversations/:id — title-only rename. Driven by the
  # conversation-title Stimulus controller.
  def update
    title = params[:title].to_s.strip
    return head(:unprocessable_entity) if title.blank?

    @conversation.update!(title: title)
    @conversation.broadcast_title_change!
    head :ok
  end

  def cancel
    @conversation.request_cancel!
    head :no_content
  end

  def archived
    @archived_conversations = current_user.conversations.for_team(current_team).archived.recent
  end

  def archive
    @conversation.archive!
    flash[:notice] = "Conversation archived."
    flash[:undo_archive_id] = @conversation.id # consumed by the toast Undo
    redirect_to root_path
  end

  def unarchive
    @conversation.unarchive!
    flash[:notice] = "Conversation restored."
    redirect_to @conversation
  end

  def star
    @conversation.star!
    respond_with_panel "conversations/star"
  end

  def unstar
    @conversation.unstar!
    respond_with_panel "conversations/star"
  end

  def share
    @conversation.generate_share_token!
    respond_with_panel "conversations/share"
  end

  def unshare
    @conversation.revoke_share!
    respond_with_panel "conversations/share"
  end

  # Flip in-app team visibility — separate from the public share link.
  def toggle_visibility
    @conversation.update!(visibility: @conversation.visibility_team? ? :personal : :team)
    @conversation.broadcast_team_tab_dot! if @conversation.visibility_team? && !@conversation.team.personal?
    respond_with_panel "conversations/share"
  end

  private

  def set_conversation
    @conversation = current_user.conversations.find(params[:id])
  end

  # The star/share toggles re-render their inline header panel over Turbo,
  # or fall back to a full-page redirect.
  def respond_with_panel(partial)
    respond_to do |format|
      format.turbo_stream { render partial }
      format.html { redirect_to @conversation }
    end
  end
end
