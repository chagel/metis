# A public link for one artifact blob. The share unit is the blob (its
# content), so it stores no message/conversation reference — team_id is
# denormalized at create time and carries ownership from then on.
class ArtifactShare < ApplicationRecord
  belongs_to :team
  belongs_to :blob, class_name: "ActiveStorage::Blob"
  belongs_to :created_by, class_name: "User"

  before_create { self.token ||= SecureRandom.urlsafe_base64(16) }

  scope :minted_by, ->(user) { where(created_by: user) }
  # Mirrors Sharing#conversations' rule: a share is listable only for a
  # viewer who can open a conversation the blob is an artifact of — a
  # personal conversation's artifact must not leak via the Sharing page.
  scope :accessible_to, ->(user) {
    where(blob_id: Message.where(conversation: Conversation.accessible_to(user))
                          .joins(:artifacts_attachments)
                          .select("active_storage_attachments.blob_id"))
  }

  # Idempotent, and race-safe: a concurrent double-submit hits the unique
  # blob_id index and finds the winner instead of raising RecordNotUnique.
  def self.share_blob!(blob:, message:, user:)
    create_or_find_by!(blob: blob) do |share|
      share.team = message.conversation.team
      share.created_by = user
    end
  end
end
