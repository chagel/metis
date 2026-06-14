class Settings::DeveloperController < ApplicationController
  layout "settings"

  before_action :set_user

  def show
  end

  # The plaintext is shown once and never stored.
  def bridge_token
    @new_bridge_token = @user.generate_bridge_token!
    flash.now[:notice] = t("flash.settings.developer.bridge_token.notice")
    render :show
  end

  def bridge_prefs
    @user.update(bridge_prefs_params)
    redirect_to developer_path
  end

  private

  def set_user
    @user = current_user
  end

  def bridge_prefs_params
    params.require(:user).permit(:auto_claim_tasks)
  end
end
