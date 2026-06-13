# Send and revoke invitations for the active team. Acceptance lives in
# the top-level InvitationsController (the invitee may not be a member
# of this team yet).
class Settings::InvitationsController < ApplicationController
  before_action :require_team_admin!
  before_action :reject_personal_team!, only: :create

  def create
    invitation = current_team.invitations.new(invitation_params)
    invitation.invited_by = current_user
    invitation.role = invited_role
    if invitation.save
      TeamMailer.invitation(invitation).deliver_later
      redirect_to team_path, notice: t("flash.settings.invitations.create.notice", email: invitation.email)
    else
      redirect_to team_path, alert: invitation.errors.full_messages.to_sentence
    end
  end

  # Re-send a still-pending invite (accepted ones 404), re-arming its
  # expiry so the emailed link is valid again.
  def resend
    invitation = current_team.invitations.pending.find(params[:id])
    unless invitation.resendable?
      redirect_to team_path, alert: t("flash.settings.invitations.resend.too_soon")
      return
    end

    invitation.reissue!
    TeamMailer.invitation(invitation).deliver_later
    redirect_to team_path, notice: t("flash.settings.invitations.resend.notice", email: invitation.email)
  end

  def destroy
    current_team.invitations.find(params[:id]).destroy
    redirect_to team_path, notice: t("flash.settings.invitations.destroy.notice")
  end

  private

  def invitation_params
    params.require(:invitation).permit(:email)
  end

  # role grants privilege, so it's resolved against an allowlist rather
  # than mass-assigned — anything off-list (incl. tampered "owner")
  # falls back to the least-privileged member.
  def invited_role
    role = params.dig(:invitation, :role)
    Invitation::INVITABLE_ROLES.include?(role) ? role : "member"
  end
end
