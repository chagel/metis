# Account credentials — change email or password, delete the account —
# for the signed-in user. Profile *preferences* live in
# ProfilesController; this is the security surface, so credential changes
# go through Devise's password-protected update.
class Settings::AccountsController < ApplicationController
  layout "settings"

  def show
    @user = current_user
  end

  def update
    @user = current_user
    if @user.update_with_password(account_params)
      # A password change rotates the auth token and would sign them out;
      # re-establish the session so they stay on the page.
      bypass_sign_in(@user)
      redirect_to account_path, notice: "Account updated."
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
    redirect_to new_user_session_path, notice: "Your account has been deleted."
  end

  private

  def account_params
    params.require(:user).permit(:email, :password, :password_confirmation, :current_password)
  end
end
