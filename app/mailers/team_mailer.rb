class TeamMailer < ApplicationMailer
  def invitation(invitation)
    @invitation = invitation
    @team = invitation.team
    @inviter = invitation.invited_by
    # Link to the show page (GET); the user confirms there with a button
    # that POSTs to accept. Linking accept_invitation_url directly 404s —
    # a clicked email link is a GET, but accept is POST-only.
    @accept_url = invitation_url(invitation.token)

    mail to: invitation.email,
         subject: default_i18n_subject(inviter: @inviter.display_label, team: @team.name)
  end
end
