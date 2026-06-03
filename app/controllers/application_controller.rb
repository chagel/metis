class ApplicationController < ActionController::Base
  include Pagy::Method

  allow_browser versions: :modern
  stale_when_importmap_changes

  before_action :authenticate_user!
  around_action :with_user_locale, if: :user_signed_in?
  around_action :with_user_timezone, if: :user_signed_in?

  helper_method :current_team, :current_membership, :team_manager?,
                :pending_invitation, :registration_offered?

  SIDEBAR_PAGE_SIZE = 30

  private

  # The team this request acts in. Session-backed and always validated
  # against membership, so a stale or forged id can never reach a team
  # the user isn't in (docs/tenancy.md). Falls back to the personal
  # team-of-one when nothing is selected.
  def current_team
    @current_team ||=
      (session[:current_team_id] && current_user.teams.find_by(id: session[:current_team_id])) ||
      current_user.personal_team
  end

  def current_membership
    @current_membership ||= current_user.memberships.find_by(team: current_team)
  end

  # Admins and owners curate the team's shared tools (skills, connectors,
  # projects); plain members use them. The view counterpart of
  # require_team_admin! — used to hide write controls.
  def team_manager?
    current_membership&.manages_team? || false
  end

  def require_team_admin!
    return if current_membership&.manages_team?

    redirect_to team_path, alert: "You don't have permission to manage this team."
  end

  def require_team_owner!
    return if current_membership&.owner?

    redirect_to team_path, alert: "Only the team owner can do that."
  end

  # Deployment-level authority, orthogonal to team membership: the
  # superuser curates the shared LLM catalog. Granted out-of-band
  # (`rake superuser:grant`), never through a team role (docs/tenancy.md).
  def require_superuser!
    return if current_user.superuser?

    redirect_to models_path, alert: "Only a superuser can change the model catalog."
  end

  # Roster operations (rename, delete, invite, leave) only make sense on
  # a shared team — a personal workspace is a team-of-one.
  def reject_personal_team!
    return unless current_team.personal?

    redirect_to team_path, alert: "That isn't available for your personal workspace."
  end

  # Cast a request param to a real boolean ("1"/"true"/"on" -> true, etc.).
  def boolean_param(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  # After signing in or up, return to a pending invitation when one is
  # stashed (InvitationsController#show) — the 99% case is a brand-new
  # invitee who just created an account. Inherited by Devise's session /
  # registration / omniauth controllers, so it covers password and OAuth.
  def after_sign_in_path_for(resource)
    token = session.delete(:pending_invitation_token)
    return invitation_path(token) if token.present? && Invitation.exists?(token: token)

    super
  end

  # The still-pending invitation a signed-out visitor is mid-acceptance
  # of (stashed by InvitationsController#show) — lets the auth pages tell
  # them which email to register/sign in with so it matches the invite.
  def pending_invitation
    return @pending_invitation if defined?(@pending_invitation)

    token = session[:pending_invitation_token]
    @pending_invitation = token.present? ? Invitation.pending.find_by(token: token) : nil
  end

  # Account creation is the access boundary (every account runs the agent
  # on the deployment's shared keys), so it's invite-only by default. The
  # very first account is allowed as the bootstrap; an open deployment
  # lets anyone in.
  def registration_open?
    Rails.configuration.x.registration_mode == :open
  end

  # Whether to even show the sign-up form: open, the bootstrap, or someone
  # mid-acceptance of an invite.
  def registration_offered?
    registration_open? || User.none? || pending_invitation.present?
  end

  # Whether `email` may actually create an account — the invite gate. The
  # invited email must match so one invite link mints one account, not many.
  def registration_allowed_for?(email)
    return true if registration_open? || User.none?

    pending_invitation.present? && pending_invitation.email == email.to_s.strip.downcase
  end

  def with_user_locale(&block)
    I18n.with_locale(current_user.language.presence || I18n.default_locale, &block)
  end

  # TimeZone[] guard: detect_timezone bypasses validation via update_column,
  # and Time.use_zone raises on unknown identifiers.
  def with_user_timezone(&block)
    zone = current_user.timezone.presence
    return yield unless zone && ActiveSupport::TimeZone[zone]

    Time.use_zone(zone, &block)
  end

  # Archived lives on its own page (conversations#archived), not as a sidebar
  # scope — it's deliberately kept out of the high-level list.
  SIDEBAR_FILTERS = %w[active shared starred].freeze

  # :countless (LIMIT+1 probe, no COUNT). Don't switch to headless: true —
  # that drops the probe and `@sidebar_pagy.next` goes nil.
  def set_sidebar
    @sidebar_filter = SIDEBAR_FILTERS.include?(params[:filter]) ? params[:filter] : "active"
    # No "shared" scope in a team of one — there's nobody to share with.
    @sidebar_filter = "active" if @sidebar_filter == "shared" && current_team.personal?
    @sidebar_pagy, @conversations = pagy(
      :countless, sidebar_scope(@sidebar_filter), limit: SIDEBAR_PAGE_SIZE
    )
  end

  # "shared" spans the whole team (every member's shared conversations);
  # "active" and "starred" are the signed-in user's own, archived excluded.
  # All ordered by recency for the same bucketed sidebar list.
  def sidebar_scope(filter)
    mine = current_user.conversations.for_team(current_team)
    case filter
    when "shared"  then current_team.conversations.shared.active.recent
    when "starred" then mine.starred.active.recent
    else                mine.active.recent
    end
  end
end
