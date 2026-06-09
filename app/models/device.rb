# A user's enrolled local machine. A workflow can delegate a step to a
# coding agent running on this device (see docs/local-bridge.md); the
# device pulls the task over the bridge REST surface, authenticated by its
# enrollment token. Metis stores only the token's digest.
class Device < ApplicationRecord
  # A device is "online" if its daemon has heartbeat-stamped last_seen_at
  # within this window — drives only notification, never the engine.
  PRESENCE_WINDOW = 45.seconds

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true

  belongs_to :team
  belongs_to :user

  scope :online, -> { where(last_seen_at: PRESENCE_WINDOW.ago..) }

  before_validation :mint_token, on: :create

  # The plaintext enrollment token, available only on the instance that
  # just minted it — never reconstructable from the stored digest.
  attr_reader :plaintext_token

  # Resolve a bearer token to its device, or nil. The daemon-facing analog
  # of authenticate_user!.
  def self.authenticate(token)
    return if token.blank?
    find_by(token_digest: digest(token))
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end

  def online?
    last_seen_at.present? && last_seen_at > PRESENCE_WINDOW.ago
  end

  # Stamped by the daemon's heartbeat — the freshness the `online` scope reads.
  def seen!
    update_column(:last_seen_at, Time.current)
  end

  private

  def mint_token
    return if token_digest.present?

    @plaintext_token = "mbd_#{SecureRandom.urlsafe_base64(32)}"
    self.token_digest = self.class.digest(@plaintext_token)
  end
end
