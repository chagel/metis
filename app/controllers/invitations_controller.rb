# Accept a team invitation from its tokenized link. The landing page
# (show) is public so an invited user who has no account yet sees what
# they're joining and can sign up; we stash the token so they return
# here after auth (see ApplicationController#after_sign_in_path_for).
# accept stays sign-in-gated and requires the signed-in user's email to
# match the address the invite was sent to.
class InvitationsController < ApplicationController
  layout "application"
  skip_before_action :authenticate_user!, only: :show

  def show
    @invitation = Invitation.find_by!(token: params[:token])

    if user_signed_in?
      redirect_if_settled(@invitation)
    elsif !@invitation.accepted? && !@invitation.expired?
      session[:pending_invitation_token] = @invitation.token
    end
  end

  def accept
    invitation = Invitation.find_by!(token: params[:token])
    return if redirect_if_settled(invitation)

    return redirect_to(root_path, alert: t("flash.invitations.accept.expired")) if invitation.expired?
    unless invitation.for?(current_user)
      return redirect_to invitation_path(invitation.token),
                         alert: t("flash.invitations.accept.wrong_email", email: invitation.email)
    end

    invitation.accept!(current_user)
    session[:current_team_id] = invitation.team_id
    redirect_to root_path, notice: t("flash.invitations.accept.notice", name: invitation.team.name)
  end

  private

  # An already-accepted invite shouldn't 404 on a double-submit or back —
  # send the user home, into the team if they're a member of it.
  def redirect_if_settled(invitation)
    return false unless invitation.accepted?

    if invitation.team.members.include?(current_user)
      session[:current_team_id] = invitation.team_id
      redirect_to root_path, notice: t("flash.invitations.accept.already_member", name: invitation.team.name)
    else
      redirect_to root_path, alert: t("flash.invitations.accept.already_used")
    end
    true
  end
end
