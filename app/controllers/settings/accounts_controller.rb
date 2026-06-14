class Settings::AccountsController < ApplicationController
  layout "settings"

  before_action :set_user, only: %i[show update]

  def show
  end

  def update
    if @user.update_with_password(account_params)
      # A password change rotates the auth token and would sign them out;
      # re-establish the session so they stay on the page.
      bypass_sign_in(@user)
      redirect_to account_path, notice: t("flash.settings.accounts.update.notice")
    else
      render :show, status: :unprocessable_entity
    end
  end

  def destroy
    user = current_user
    # A personal team-of-one is meaningless without its owner; take it
    # with them. Shared teams (which may have other members) are left
    # intact — the membership goes via User's dependent: :destroy.
    user.personal_team&.destroy
    user.destroy
    reset_session
    redirect_to new_user_session_path, notice: t("flash.settings.accounts.destroy.notice")
  end

  private

  def set_user
    @user = current_user
    # Only providers we actually support for sign-in — not connector
    # authorizations (e.g. Linear), which also leave an Identity behind
    # but can't be used to log in.
    @identities = @user.identities
      .where(provider: OauthBroker::STRATEGY_TO_PROVIDER.keys).order(:provider)
  end

  def account_params
    params.require(:user).permit(:email, :password, :password_confirmation, :current_password)
  end
end
