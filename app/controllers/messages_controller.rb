class MessagesController < ApplicationController
  include Composing

  before_action :set_conversation

  def create
    content = composed_content
    uploads = composed_uploads
    return head(:unprocessable_entity) if content.blank? && uploads.empty?
    return head(:conflict) if @conversation.turn_in_progress?

    if (error = upload_error(uploads))
      return render_composer_error(@conversation, error)
    end

    @user_message, @assistant_message = start_turn(@conversation, content, uploads)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @conversation }
    end
  rescue ActiveRecord::RecordNotUnique
    head(:conflict) # in-progress-turn index caught a race
  end

  def fork
    message = @conversation.messages.find(params[:id])
    return head(:unprocessable_entity) unless message.assistant? && message.done?

    fork = Agent::ConversationForker.new(message, by: current_user).call
    redirect_to fork
  end

  private

  def set_conversation
    @conversation = current_user.conversations.find(params[:conversation_id])
  end
end
