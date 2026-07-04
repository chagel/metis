require "test_helper"

class Users::NativeAuthControllerTest < ActionDispatch::IntegrationTest
  AUDIENCE = "test-ios-client.apps.googleusercontent.com".freeze

  setup do
    @rsa = OpenSSL::PKey::RSA.new(2048)
    @jwk = JWT::JWK.new(@rsa)
    ENV["GOOGLE_OAUTH_IOS_CLIENT_ID"] = AUDIENCE
  end

  teardown do
    ENV.delete("GOOGLE_OAUTH_IOS_CLIENT_ID")
  end

  test "rejects a blank token" do
    post google_native_auth_path

    assert_redirected_to new_user_session_path
    assert_equal I18n.t("flash.users.omniauth_callbacks.sign_in_failed"), flash[:alert]
  end

  test "rejects a malformed token without fetching keys" do
    post google_native_auth_path, params: { id_token: "not-a-jwt" }

    assert_redirected_to new_user_session_path
    assert flash[:alert].present?
  end

  test "rejects a token signed for another audience" do
    with_google_jwks do
      post google_native_auth_path, params: { id_token: id_token(aud: "someone-else") }

      assert_redirected_to new_user_session_path
      assert flash[:alert].present?
    end
  end

  test "rejects an unverified email" do
    with_google_jwks do
      post google_native_auth_path, params: { id_token: id_token(email_verified: false) }

      assert_redirected_to new_user_session_path
      assert flash[:alert].present?
    end
  end

  test "signs in with a valid token" do
    email = "native-#{SecureRandom.hex(4)}@example.com"
    with_google_jwks do
      post google_native_auth_path, params: { id_token: id_token(email: email) }
    end

    assert_redirected_to root_path
    assert User.find_by(email: email).present?
    follow_redirect!
    assert_response :success
  end

  test "matches an existing account by verified email instead of minting a duplicate" do
    user = User.create!(email: "existing-native@example.com", password: Devise.friendly_token)
    with_google_jwks do
      post google_native_auth_path, params: { id_token: id_token(email: user.email) }
    end

    assert_redirected_to root_path
    assert_equal 1, User.where(email: user.email).count
    assert user.identities.exists?(provider: "google_oauth2")
  end

  private

  def with_google_jwks(&)
    jwks = { keys: [ @jwk.export ] }
    with_stub(Users::NativeAuthController, :google_jwks, -> { jwks }, &)
  end

  def id_token(email: "native@example.com", aud: AUDIENCE, email_verified: true)
    payload = {
      iss: "https://accounts.google.com", aud: aud, sub: "g-native-1",
      exp: 1.hour.from_now.to_i, email: email, email_verified: email_verified,
      name: "Native User", picture: nil
    }
    JWT.encode(payload, @rsa, "RS256", kid: @jwk.kid)
  end
end
