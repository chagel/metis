require "test_helper"

class InvitationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @inviter = User.create!(email: "owner@example.com", password: "password123")
    @team = Team.create!(name: "Acme")
    @inviter.memberships.create!(team: @team, role: :owner)
    @invitee = User.create!(email: "new@example.com", password: "password123")
    @invitation = @team.invitations.create!(email: "new@example.com", role: :admin, invited_by: @inviter)
  end

  test "the invite landing is public and shows a path to create an account" do
    get invitation_path(@invitation.token)
    assert_response :success
    assert_select "h2", text: /You're invited/
    assert_select "a[href=?]", new_user_registration_path(email: @invitation.email)
  end

  test "accepting still requires sign in" do
    assert_no_difference -> { @team.memberships.count } do
      post accept_invitation_path(@invitation.token)
    end
    assert_redirected_to new_user_session_path
  end

  test "after signing in, you land back on a stashed invitation" do
    get invitation_path(@invitation.token) # stashes the token while signed out
    post user_session_path, params: { user: { email: @invitee.email, password: "password123" } }
    assert_redirected_to invitation_path(@invitation.token)
  end

  test "an expired invitation is not stashed, so signing in lands in the app" do
    @invitation.update!(expires_at: 1.day.ago)
    get invitation_path(@invitation.token) # signed out — must not stash an expired token
    post user_session_path, params: { user: { email: @invitee.email, password: "password123" } }
    assert_redirected_to root_path
  end

  test "the auth pages tell a mid-acceptance visitor which email to use" do
    get invitation_path(@invitation.token) # stashes the token while signed out

    get new_user_registration_path
    assert_select ".auth-note", /#{Regexp.escape(@invitation.email)}/

    get new_user_session_path
    assert_select ".auth-note", /#{Regexp.escape(@invitation.email)}/
  end

  test "accepting with the matching email joins the team and switches into it" do
    sign_in @invitee
    assert_difference -> { @team.memberships.count }, 1 do
      post accept_invitation_path(@invitation.token)
    end
    assert @team.memberships.find_by(user: @invitee).admin?
    assert_redirected_to root_path
    assert @invitation.reload.accepted_at.present?

    # Switched into the joined team: its conversations now scope the sidebar.
    @invitee.conversations.create!(team: @team, title: "In Acme")
    get conversations_path
    assert_select ".sidebar .convo .tt", text: "In Acme"
  end

  test "re-accepting after joining is idempotent, not a 404" do
    sign_in @invitee
    post accept_invitation_path(@invitation.token)

    assert_no_difference -> { @team.memberships.count } do
      post accept_invitation_path(@invitation.token)
      get invitation_path(@invitation.token)
    end
    assert_redirected_to root_path
    assert_equal "You're already in #{@team.name}.", flash[:notice]
  end

  test "cannot accept an invitation sent to a different address" do
    other = User.create!(email: "someone@else.com", password: "password123")
    sign_in other
    assert_no_difference -> { @team.memberships.count } do
      post accept_invitation_path(@invitation.token)
    end
    assert_redirected_to invitation_path(@invitation.token)
  end

  test "cannot accept an expired invitation" do
    @invitation.update!(expires_at: 1.day.ago)
    sign_in @invitee
    assert_no_difference -> { @team.memberships.count } do
      post accept_invitation_path(@invitation.token)
    end
    assert_redirected_to root_path
  end

  test "an unknown token 404s" do
    sign_in @invitee
    get invitation_path("nope")
    assert_response :not_found
  end
end
