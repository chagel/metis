require "test_helper"

class Settings::InvitationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActionMailer::TestHelper

  setup do
    @user = User.create!(email: "owner@example.com", password: "password123")
    @team = Team.create!(name: "Acme")
    sign_in @user
  end

  def act_in(team)
    post switch_team_path(team), headers: { "HTTP_REFERER" => root_path }
  end

  test "an admin can send an invitation and an email is enqueued" do
    @user.memberships.create!(team: @team, role: :admin)
    act_in(@team)

    assert_difference -> { @team.invitations.pending.count }, 1 do
      assert_enqueued_emails 1 do
        post team_invitations_path, params: { invitation: { email: "new@example.com", role: "member" } }
      end
    end
    assert_redirected_to team_path
  end

  test "a plain member cannot invite" do
    @user.memberships.create!(team: @team, role: :member)
    act_in(@team)

    assert_no_difference -> { @team.invitations.count } do
      post team_invitations_path, params: { invitation: { email: "new@example.com", role: "member" } }
    end
    assert_redirected_to team_path
  end

  test "cannot invite into the personal workspace" do
    assert_no_difference -> { Invitation.count } do
      post team_invitations_path, params: { invitation: { email: "new@example.com", role: "member" } }
    end
    assert_redirected_to team_path
  end

  test "a bad email is reported, not saved" do
    @user.memberships.create!(team: @team, role: :owner)
    act_in(@team)

    assert_no_difference -> { @team.invitations.count } do
      post team_invitations_path, params: { invitation: { email: "nope", role: "member" } }
    end
    assert_redirected_to team_path
  end

  test "an admin can resend a pending invitation once the cooldown passes, re-arming its expiry" do
    @user.memberships.create!(team: @team, role: :admin)
    act_in(@team)
    invitation = @team.invitations.create!(email: "new@example.com", role: :member, invited_by: @user)

    travel Invitation::RESEND_COOLDOWN + 1.minute do
      assert_enqueued_emails 1 do
        post resend_team_invitation_path(invitation)
      end
      assert_redirected_to team_path
      assert_in_delta Invitation::EXPIRES_IN.from_now, invitation.reload.expires_at, 1.second
    end
  end

  test "resending within the cooldown is throttled, not re-sent" do
    @user.memberships.create!(team: @team, role: :admin)
    act_in(@team)
    invitation = @team.invitations.create!(email: "new@example.com", role: :member, invited_by: @user)

    assert_no_enqueued_emails do
      post resend_team_invitation_path(invitation)
    end
    assert_redirected_to team_path
  end

  test "a plain member cannot resend" do
    @user.memberships.create!(team: @team, role: :member)
    act_in(@team)
    invitation = @team.invitations.create!(email: "new@example.com", role: :member, invited_by: @user)

    assert_no_enqueued_emails do
      post resend_team_invitation_path(invitation)
    end
    assert_redirected_to team_path
  end

  test "an owner can revoke a pending invitation" do
    @user.memberships.create!(team: @team, role: :owner)
    act_in(@team)
    invitation = @team.invitations.create!(email: "new@example.com", role: :member, invited_by: @user)

    assert_difference -> { @team.invitations.count }, -1 do
      delete team_invitation_path(invitation)
    end
    assert_redirected_to team_path
  end
end
