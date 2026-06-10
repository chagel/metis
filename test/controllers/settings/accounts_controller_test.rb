require "test_helper"

class Settings::AccountsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "acct-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in @user
  end

  test "show renders the account page" do
    get account_path
    assert_response :success
    assert_select "form.account-form"
  end

  test "bridge_token generates a token and shows it once" do
    post account_bridge_token_path
    assert_response :success
    assert @user.reload.bridge_token_digest.present?
    # The paste-into-your-agent blob carries skill install, mcp add, and token.
    assert_select ".bridge-token .bridge-paste", /mbt_/
    assert_select ".bridge-token .bridge-paste", /claude mcp add/
    assert_select ".bridge-token .bridge-paste", %r{api/bridge/skill}

    # Shown only on the generating response, never again.
    get account_path
    assert_select ".bridge-token .bridge-paste", count: 0
  end

  test "bridge_token regenerates and rotates the digest" do
    post account_bridge_token_path
    first_digest = @user.reload.bridge_token_digest
    post account_bridge_token_path
    assert_not_equal first_digest, @user.reload.bridge_token_digest
  end

  test "bridge_token requires a signed-in user" do
    sign_out @user
    post account_bridge_token_path
    assert_redirected_to new_user_session_path
  end

  test "update changes the email with the correct current password" do
    new_email = "moved-#{SecureRandom.hex(4)}@example.com"
    patch account_path, params: { user: {
      email: new_email, current_password: "password123"
    } }
    assert_redirected_to account_path
    assert_equal new_email, @user.reload.email
  end

  test "update changes the password and keeps the user signed in" do
    patch account_path, params: { user: {
      password: "newpassword456", password_confirmation: "newpassword456",
      current_password: "password123"
    } }
    assert_redirected_to account_path
    assert @user.reload.valid_password?("newpassword456")

    # Still authenticated — a follow-up request isn't bounced to sign-in.
    get account_path
    assert_response :success
  end

  test "update is rejected when the current password is wrong" do
    original = @user.email
    patch account_path, params: { user: {
      email: "nope-#{SecureRandom.hex(4)}@example.com", current_password: "wrong"
    } }
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.email
  end

  test "update is rejected when password confirmation does not match" do
    patch account_path, params: { user: {
      password: "newpassword456", password_confirmation: "mismatch",
      current_password: "password123"
    } }
    assert_response :unprocessable_entity
    assert @user.reload.valid_password?("password123")
  end

  test "destroy deletes the account and its personal team, then signs out" do
    personal_team = @user.personal_team
    assert_difference [ "User.count", "Team.count" ], -1 do
      delete account_path
    end
    assert_redirected_to new_user_session_path
    assert_not User.exists?(@user.id)
    assert_not Team.exists?(personal_team.id)
  end
end
