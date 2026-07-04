require "net/http"

# Session-less sign-in for the native apps (clients/../metis-ios). Google
# rejects OAuth inside webviews ("disallowed_useragent"), so the app runs
# Google Sign-In natively and posts the resulting ID token here. The token
# is verified against Google's JWKS — its signature and audience are the
# authenticity proof, so CSRF verification is skipped. Ported from themis.
class Users::NativeAuthController < ApplicationController
  skip_before_action :verify_authenticity_token, only: :google
  skip_before_action :authenticate_user!, only: :google

  GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs".freeze
  GOOGLE_ISSUERS = [ "https://accounts.google.com", "accounts.google.com" ].freeze

  # Class-level so tests can stub it; reached lazily through the decode
  # lambda, so a token that fails before signature checks never fetches.
  def self.google_jwks
    Rails.cache.fetch("native_auth/google_jwks", expires_in: 1.hour) do
      response = Net::HTTP.get_response(URI(GOOGLE_JWKS_URL))
      raise "JWKS fetch failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body, symbolize_names: true)
    end
  end

  def google
    payload = verify_google_id_token(params[:id_token].to_s)
    return reject("invalid_token") unless payload
    return reject("email_unverified") unless payload["email_verified"]

    user = User.from_omniauth(
      build_auth_hash(payload),
      allow_signup: registration_allowed_for?(payload["email"])
    )
    return reject("user_persistence_failed") unless user.persisted?

    user.remember_me = true
    sign_in user, event: :authentication
    redirect_to root_path, status: :see_other
  rescue User::SignupNotAllowed
    redirect_to new_user_session_path, alert: t("flash.shared.invite_only"), status: :see_other
  end

  private

  def reject(reason)
    Rails.logger.warn("[NativeAuth] rejected: #{reason}")
    redirect_to new_user_session_path,
                alert: t("flash.users.omniauth_callbacks.sign_in_failed"),
                status: :see_other
  end

  def verify_google_id_token(token)
    return nil if token.blank?

    JWT.decode(
      token, nil, true,
      algorithms: [ "RS256" ],
      jwks: ->(_options) { self.class.google_jwks },
      iss: GOOGLE_ISSUERS,
      verify_iss: true,
      aud: allowed_audiences,
      verify_aud: true
    ).first
  rescue JWT::DecodeError => e
    Rails.logger.warn("[NativeAuth] JWT decode failed: #{e.class}: #{e.message}")
    nil
  end

  # The iOS client mints the token; the web client id is kept for any
  # future client that exchanges a server-audience token.
  def allowed_audiences
    [ ENV["GOOGLE_OAUTH_IOS_CLIENT_ID"], ENV["GOOGLE_OAUTH_CLIENT_ID"] ].compact_blank
  end

  # email_verified: true is what User.email_verified_for? trusts to match
  # by email — without it a first native sign-in of an existing web user
  # would mint a duplicate noreply account. The caller already rejected
  # unverified tokens.
  def build_auth_hash(payload)
    OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: payload["sub"],
      info: {
        email: payload["email"],
        email_verified: true,
        name: payload["name"],
        image: payload["picture"]
      }
    )
  end
end
