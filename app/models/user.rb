class User < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :omniauthable, omniauth_providers: %i[github google_oauth2]

  # Raised by from_omniauth when an OAuth sign-in would create a new
  # account but the deployment's invite-only gate forbids it.
  SignupNotAllowed = Class.new(StandardError)

  has_many :memberships, dependent: :destroy
  has_many :teams, through: :memberships
  has_many :conversations, dependent: :destroy
  has_many :connector_credentials, dependent: :destroy
  has_many :identities, dependent: :destroy
  has_many :oauth_grants, dependent: :destroy

  # An uploaded avatar overrides `avatar_url` (the OAuth-cached URL);
  # see `AvatarHelper#avatar_for` for the resolution order.
  has_one_attached :avatar

  AVATAR_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/gif].freeze
  AVATAR_MAX_BYTES     = 2.megabytes

  validate :avatar_acceptable

  after_create :create_personal_team

  # Locales the UI is translated into. v1 ships English only; the
  # selector is here so future locales drop in without a schema or
  # controller change.
  AVAILABLE_LANGUAGES = %w[en].freeze

  # `system` defers to the OS / browser preference (handled by the
  # no-flash script in the head). Explicit `light`/`dark` overrides it.
  THEMES = %w[system light dark].freeze

  # Trim whitespace and treat empty strings as nil for every profile
  # field — keeps a stray space in the form from sneaking past the
  # inclusion/length validators below and causing surprises downstream
  # (a display_name like " " is technically "present" but reads blank).
  normalizes :display_name, :timezone, :language, :preferred_model, :theme,
             with: ->(value) { value.is_a?(String) ? value.strip.presence : value }
  normalizes :about_you, :custom_instructions,
             with: ->(value) { value.is_a?(String) ? value.strip.presence : value }

  # Profile fields are validated only when the user submits the profile
  # form (context :profile_update). Sign-up still works without them,
  # and OAuth-created users don't carry a display name at all.
  validates :display_name, presence: true, length: { maximum: 80 },
            on: :profile_update
  validates :timezone,
            inclusion: { in: ->(_) { ActiveSupport::TimeZone.all.map(&:name) } },
            allow_blank: true
  validates :language, inclusion: { in: AVAILABLE_LANGUAGES }, allow_blank: true
  validates :theme, inclusion: { in: THEMES }, allow_blank: true
  validates :about_you, length: { maximum: 2_000 }
  validates :custom_instructions, length: { maximum: 4_000 }
  validate :preferred_model_known

  # What to show in the UI for this user — the display name they picked,
  # otherwise the email we have on file (the noreply synth is ugly but
  # at least stable).
  def display_label
    display_name.presence || email
  end

  # Two-letter (or one-letter) initials for the avatar fallback. Built
  # from display name when set, otherwise from the local part of the
  # email — splits on whitespace and the usual email separators.
  def initials
    source = display_name.presence || email.to_s.split("@", 2).first
    return "?" if source.blank?

    parts = source.split(/[\s@._\-+]+/).reject(&:blank?)
    letters = parts.first(2).map { |part| part[0] }.join
    (letters.presence || source[0]).upcase
  end

  # The team-of-one created at signup — owner of this user's personal
  # resources (docs/tenancy.md).
  def personal_team
    teams.find_by(personal: true)
  end

  NOREPLY_EMAIL_SUFFIX = ".users.noreply.metis".freeze

  # Addresses we'd never have set if the user had given us a real one.
  # Anchored, not substring — `alex@users.noreply.corp.com` (a real GHE
  # noreply domain) is a real email and must not be rewritten.
  #
  # - metis's own synth (User.noreply_email): `<uid>+<handle>@<provider>.users.noreply.metis`
  # - GitHub's private-email pseudo-address: `<id>+<login>@users.noreply.github.com`
  PLACEHOLDER_EMAIL_PATTERNS = [
    /\.users\.noreply\.metis\z/,
    /\A\d+\+[^@]+@users\.noreply\.github\.com\z/
  ].freeze

  # Identity-first lookup; email fallback only when the provider
  # has verified the address (otherwise a forged email claim takes
  # over the matching user). Untrusted emails fall through to a
  # synthetic noreply, creating a fresh account.
  #
  # The transaction + retry handles the concurrent-first-sign-in
  # race: two callbacks for the same (provider, uid) both miss
  # Identity.find_by; the loser hits the unique index, rolls back,
  # retries, and the second pass finds the winner's identity.
  # allow_signup gates brand-new account creation (the invite-only
  # boundary); signing in an existing user or linking an identity to one
  # is always allowed. Raises SignupNotAllowed when a new account would be
  # created but isn't permitted.
  def self.from_omniauth(auth, allow_signup: true)
    attempts = 0
    begin
      identity = Identity.find_by(provider: auth.provider, uid: auth.uid.to_s)
      if identity
        backfill_real_email(identity.user, auth)
        backfill_avatar_url(identity.user, auth)
        return identity.user
      end

      transaction do
        email = trusted_email(auth) || noreply_email(auth)
        user = find_or_initialize_by(email: email)
        raise SignupNotAllowed if user.new_record? && !allow_signup

        user.password = Devise.friendly_token[0, 32] if user.new_record?
        user.avatar_url = auth.info.image if auth.info.image.present?
        user.save!
        user.identities.create!(provider: auth.provider, uid: auth.uid.to_s)
        user
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
      attempts += 1
      if attempts == 1 && Identity.exists?(provider: auth.provider, uid: auth.uid.to_s)
        Rails.logger.info(
          "User.from_omniauth retrying after race: #{error.class}: #{error.message}"
        )
        retry
      end
      raise
    end
  end

  def self.trusted_email(auth)
    return nil if auth.info.email.blank?
    return nil unless email_verified_for?(auth)

    auth.info.email
  end

  # GitHub's user:email scope guarantees the primary email is verified.
  # Google exposes an explicit boolean — read both surfaces (newer
  # omniauth-google_oauth2 puts it on info, older only on extra.raw_info)
  # and treat anything but explicit true as unverified.
  def self.email_verified_for?(auth)
    case auth.provider
    when "github"
      true
    when "google_oauth2"
      verified = auth.info&.[](:email_verified)
      verified = auth.extra&.raw_info&.[]("email_verified") if verified.nil?
      verified == true || verified == "true"
    else
      false
    end
  end

  # A stable synthetic address used when a provider's callback doesn't
  # include an email (e.g. a GitHub App without the "Email addresses"
  # permission). The user is still matched on subsequent sign-ins by
  # identity, not by email.
  def self.noreply_email(auth)
    handle = auth.info.nickname.presence || auth.info.name.presence || "user"
    "#{auth.uid}+#{handle.parameterize}@#{auth.provider}#{NOREPLY_EMAIL_SUFFIX}"
  end

  def self.placeholder_email?(email)
    s = email.to_s
    PLACEHOLDER_EMAIL_PATTERNS.any? { |re| s.match?(re) }
  end

  # Re-cache the provider's avatar URL on every sign-in so a user who
  # changes their profile picture upstream sees it reflected. Skipped
  # when the user has uploaded their own avatar (the upload wins) and
  # when the provider stops returning an image.
  def self.backfill_avatar_url(user, auth)
    return if user.avatar.attached?
    return if auth.info.image.blank?
    return if user.avatar_url == auth.info.image

    user.update_column(:avatar_url, auth.info.image)
  end

  # Promote a placeholder noreply email to the real one when the
  # provider starts returning it (e.g. after a GitHub App gains the
  # "Email addresses" permission). Never the reverse — a sign-in
  # without auth.info.email, or with another placeholder, must not
  # overwrite a real email. Best-effort: a failed backfill (TOCTOU
  # collision, provider returned a Devise-invalid address) logs and
  # returns rather than crashing the sign-in.
  def self.backfill_real_email(user, auth)
    return unless auth.info.email.present?
    return if placeholder_email?(auth.info.email)
    return unless placeholder_email?(user.email)
    return if where.not(id: user.id).exists?(email: auth.info.email)

    user.update!(email: auth.info.email)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    Rails.logger.warn(
      "User#backfill_real_email skipped for user #{user.id}: #{error.class}: #{error.message}"
    )
  end

  private

  # Send Devise's emails through the queue (deliver_later) like the rest
  # of our mail — async, and retried on transient Cloudflare failures via
  # MailDeliveryJob. Devise's default sends inline (deliver_now), which
  # would block the request and bypass the retry path.
  def send_devise_notification(notification, *args)
    devise_mailer.send(notification, self, *args).deliver_later
  end

  def preferred_model_known
    return if preferred_model.blank?
    return if Agent::Catalog.known_model?(preferred_model)

    errors.add(:preferred_model, "is not an available model")
  end

  # Every user gets a personal team (a team of one) at signup.
  def create_personal_team
    team = Team.create!(name: email, personal: true)
    memberships.create!(team: team, role: :owner)
  end

  # Rejects oversize files and unsupported formats *before* the
  # attachment is persisted. We don't purge the blob here — a record
  # that fails validation never gets the attachment committed.
  def avatar_acceptable
    return unless avatar.attached?

    blob = avatar.blob
    if blob.byte_size > AVATAR_MAX_BYTES
      errors.add(:avatar, "must be under #{AVATAR_MAX_BYTES / 1.megabyte}MB")
    end
    unless AVATAR_CONTENT_TYPES.include?(blob.content_type)
      errors.add(:avatar, "must be JPEG, PNG, WebP, or GIF")
    end
  end
end
