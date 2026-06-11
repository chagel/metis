# Enforces the invite-only signup gate on the password registration form.
# The OAuth signup path is gated separately in OmniauthCallbacksController
# (both funnel through ApplicationController#registration_allowed_for?).
class Users::RegistrationsController < Devise::RegistrationsController
  before_action :require_registration_offered, only: :new
  before_action :require_registration_allowed, only: :create

  # Account settings live under /settings/account now (Settings::Accounts).
  # Devise still routes /users/edit, so point any stale link at the
  # canonical page rather than rendering a second account form.
  def edit
    redirect_to account_path
  end

  private

  def require_registration_offered
    deny_registration unless registration_offered?
  end

  def require_registration_allowed
    deny_registration unless registration_allowed_for?(params.dig(:user, :email))
  end

  def deny_registration
    redirect_to new_user_session_path, alert: deny_registration_alert
  end

  def deny_registration_alert
    if allowed_domains.any?
      domains = allowed_domains.map { |domain| "@#{domain}" }.to_sentence
      "Metis is invite-only — only #{domains} emails may register without an invitation."
    else
      "Metis is invite-only — ask a team admin to invite you."
    end
  end
end
