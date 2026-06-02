# Preview team emails in development at /rails/mailers/team_mailer.
# Builds an in-memory invitation — nothing is persisted.
class TeamMailerPreview < ActionMailer::Preview
  def invitation
    team = Team.new(name: "Acme")
    inviter = User.new(display_name: "Ada Lovelace", email: "ada@example.com")
    invitation = Invitation.new(
      team: team, invited_by: inviter, email: "teammate@example.com",
      role: :admin, token: "preview-token", expires_at: Invitation::EXPIRES_IN.from_now
    )

    TeamMailer.invitation(invitation)
  end
end
