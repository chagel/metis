require "test_helper"

class Users::RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    # Fixtures already create users, so we're past the first-account
    # bootstrap — these exercise the invite gate, not the bootstrap.
    @inviter = User.create!(email: "owner@example.com", password: "password123")
    @team = Team.create!(name: "Acme")
    @inviter.memberships.create!(team: @team, role: :owner)
    @invitation = @team.invitations.create!(email: "invitee@example.com", role: :member, invited_by: @inviter)
  end

  def signup_params(email)
    { user: { email: email, password: "password123", password_confirmation: "password123" } }
  end

  test "open mode lets anyone reach the form and register" do
    with_registration_mode(:open) do
      get new_user_registration_path
      assert_response :success

      assert_difference("User.count", 1) do
        post user_registration_path, params: signup_params("rando@example.com")
      end
    end
  end

  test "invite-only blocks the form and creation for an uninvited stranger" do
    with_registration_mode(:invite_only) do
      get new_user_registration_path
      assert_redirected_to new_user_session_path

      assert_no_difference("User.count") do
        post user_registration_path, params: signup_params("rando@example.com")
      end
      assert_redirected_to new_user_session_path
    end
  end

  test "invite-only lets an invitee register with the invited email" do
    with_registration_mode(:invite_only) do
      get invitation_path(@invitation.token) # stashes the pending token in session

      get new_user_registration_path
      assert_response :success

      assert_difference("User.count", 1) do
        post user_registration_path, params: signup_params(@invitation.email)
      end
    end
  end

  test "invite-only blocks registering an email other than the invited one" do
    with_registration_mode(:invite_only) do
      get invitation_path(@invitation.token)

      assert_no_difference("User.count") do
        post user_registration_path, params: signup_params("someone.else@example.com")
      end
      assert_redirected_to new_user_session_path
    end
  end

  test "the legacy account-edit route redirects to the settings account page" do
    sign_in @inviter
    get edit_user_registration_path
    assert_redirected_to account_path
  end
end
