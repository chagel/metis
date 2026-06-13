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

  test "bridge_token generates a token and shows the manual setup with the plaintext once" do
    @user.update!(auto_claim_tasks: false)
    post account_bridge_token_path
    assert_response :success
    assert @user.reload.bridge_token_digest.present?
    # In manual mode the all-in-one block installs the skill, points at the
    # MCP endpoint, and carries the freshly minted plaintext.
    assert_select ".bridge-paste", /mbt_/
    assert_select ".bridge-paste", %r{api/bridge/skill}
    assert_select ".bridge-paste", %r{api/bridge/mcp}
    assert_select ".bridge-paste", { text: /…/, count: 0 }, "plaintext, not redacted, on generation"
    assert_select ".bridge-status--fresh"

    # Instructions stay on a normal reload, but the plaintext is gone — the
    # block tells the user to regenerate rather than pasting a dead token.
    get account_path
    assert_select ".bridge-paste", /Regenerate my bridge token/
    assert_select ".bridge-paste", { text: /mbt_…/, count: 0 }, "no dead redacted token pasted on reload"
    assert_select ".bridge-status--fresh", count: 0
  end

  test "auto mode shows the daemon setup block, with the live token only when fresh" do
    post account_bridge_token_path                 # auto is the default
    assert_select ".bridge-instr-badge", text: "Auto"
    assert_select ".bridge-paste", /go install/
    assert_select ".bridge-paste", /metis install/
    assert_select ".bridge-paste", /"token": "mbt_/, "fresh generation embeds the live token"

    get account_path
    assert_select ".bridge-paste", { text: /mbt_…/, count: 0 }, "no dead redacted token in the daemon config on reload"
    assert_select ".bridge-paste", /regenerate your token/
  end

  test "the claim-mode selector is hidden until a token exists, then visible" do
    get account_path
    assert_select ".bridge-mode-selector", count: 0

    @user.generate_bridge_token!
    get account_path
    assert_select ".bridge-mode-selector"
    # Auto is the default selection.
    assert_select "input[name=?][value=true][checked]", "user[auto_claim_tasks]"
  end

  test "bridge_prefs persists the auto-claim preference" do
    @user.generate_bridge_token!
    patch account_bridge_prefs_path, params: { user: { auto_claim_tasks: "1" } }
    assert_redirected_to account_path
    assert @user.reload.auto_claim_tasks

    patch account_bridge_prefs_path, params: { user: { auto_claim_tasks: "0" } }
    assert_not @user.reload.auto_claim_tasks
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
