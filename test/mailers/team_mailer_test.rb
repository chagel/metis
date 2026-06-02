require "test_helper"

class TeamMailerTest < ActionMailer::TestCase
  test "invitation renders with the accept link and team name" do
    inviter = User.create!(email: "owner@example.com", password: "password123", display_name: "Ada")
    team = Team.create!(name: "Acme")
    inviter.memberships.create!(team: team, role: :owner)
    invitation = team.invitations.create!(email: "new@example.com", role: :member, invited_by: inviter)

    mail = TeamMailer.invitation(invitation)

    assert_equal [ "new@example.com" ], mail.to
    assert_match "Acme", mail.subject
    assert_match "Ada", mail.subject
    assert_match invitation.token, mail.body.encoded

    # The link must land on the show page (GET), not the POST-only accept
    # route — a clicked email link is always a GET.
    assert_match %r{/invitations/#{invitation.token}(?:\?|"|\s|$)}, mail.body.encoded
    assert_no_match %r{/invitations/#{invitation.token}/accept}, mail.body.encoded
  end
end
