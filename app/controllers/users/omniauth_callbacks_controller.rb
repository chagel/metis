# Sign-in vs connect-a-connector both land here; omniauth.params["connect"]
# (catalog key) splits them. See docs/connectors.md.
class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  class IdentityAlreadyLinked < StandardError; end

  def github
    handle(OauthBroker.normalize_provider("github"))
  end

  def google_oauth2
    handle(OauthBroker.normalize_provider("google_oauth2"))
  end

  def linear
    handle(OauthBroker.normalize_provider("linear"))
  end

  def failure
    redirect_to new_user_session_path, alert: "Sign-in was cancelled."
  end

  private

  def handle(provider)
    # Capture up front — Devise mutates warden session during processing.
    was_signed_in = user_signed_in?
    return_path   = was_signed_in ? root_path : new_user_session_path

    auth   = request.env["omniauth.auth"]
    params = request.env["omniauth.params"] || {}

    target =
      if was_signed_in
        attach_identity(current_user, auth)
      else
        signup_email = User.trusted_email(auth) || User.noreply_email(auth)
        User.from_omniauth(auth, allow_signup: registration_allowed_for?(signup_email))
      end
    grant_recorded = record_grant(target, auth, provider)
    # Skip activation when the grant write failed — otherwise the tile shows
    # "Connected" for a connector McpConfig drops every turn (no bearer).
    activate_connector_if_requested(target, params, auth) if grant_recorded
    finish_sign_in(target, provider)
  rescue IdentityAlreadyLinked
    redirect_to return_path,
                alert: "This #{provider.titleize} account is already linked to another Metis user."
  rescue User::SignupNotAllowed
    redirect_to new_user_session_path,
                alert: "Metis is invite-only — ask a team admin to invite you."
  rescue StandardError => error
    Rails.logger.error(
      "Omniauth(#{provider}) failed: #{error.class}: #{error.message}\n" \
      "#{error.backtrace.first(5).join("\n")}"
    )
    redirect_to new_user_session_path, alert: "Sign-in failed."
  end

  def record_grant(target, auth, provider)
    OmniauthConnector.record_grant(target, auth, provider: provider)
    true
  rescue StandardError => error
    Rails.logger.error(
      "Omniauth(#{provider}) grant write failed for user #{target&.id}: " \
      "#{error.class}: #{error.message}"
    )
    false
  end

  def activate_connector_if_requested(target, params, auth)
    catalog_key = params["connect"].presence
    return if catalog_key.blank?

    app = ConnectorCatalog.find(catalog_key)
    return unless app

    OmniauthConnector.activate_connector(target, app, auth, team: connect_team(target, params["team"]))
  rescue StandardError => error
    # Non-fatal: sign-in half already succeeded.
    Rails.logger.error(
      "Omniauth connector activation failed for user #{target&.id} app=#{params['connect']}: " \
      "#{error.class}: #{error.message}"
    )
  end

  # The team the connector belongs to — the one the user was acting in
  # when they clicked Connect, carried through the OAuth state. Validated
  # against membership (a forged id can't attach to a team they're not
  # in); falls back to the personal team.
  def connect_team(user, team_id)
    user.teams.find_by(id: team_id) || user.personal_team
  end

  def finish_sign_in(target, provider)
    if user_signed_in?
      redirect_target, redirect_options = post_connect_redirect(provider) || [
        after_sign_in_path_for(target), { notice: "Connected to #{provider.titleize}." }
      ]
      redirect_to redirect_target, **redirect_options
    else
      sign_in_and_redirect target, event: :authentication
    end
  end

  # GitHub App tokens can't see a repo until the App is installed there, so
  # bounce to the install page after connect=github. nil → default redirect.
  def post_connect_redirect(provider)
    return nil unless provider == "github"

    catalog_key = (request.env["omniauth.params"] || {})["connect"].presence
    return nil if catalog_key.blank?

    install_url = GithubApp::Config.install_url
    return nil if install_url.blank?

    [
      install_url,
      {
        allow_other_host: true,
        notice: "Connected to GitHub. Install the Metis app on the repos you want it to access, then return here."
      }
    ]
  end

  def attach_identity(user, auth)
    user.identities.find_or_create_by!(provider: auth.provider, uid: auth.uid.to_s)
    user
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    # (provider, uid) is owned by another user; both errors mean the same thing.
    raise IdentityAlreadyLinked
  end
end
