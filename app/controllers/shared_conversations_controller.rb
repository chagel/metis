class SharedConversationsController < ApplicationController
  skip_before_action :authenticate_user!

  layout "shared"

  def show
    @conversation = Conversation.find_by!(share_token: params[:token])
    @messages = @conversation.messages.includes(:sender).where(role: %i[user assistant]).chronological
  end
end
