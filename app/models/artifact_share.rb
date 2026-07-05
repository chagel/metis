# A public link for one artifact blob. The share unit is the blob (its
# content), so it stores no message/conversation reference — team_id is
# denormalized at create time and carries ownership from then on.
class ArtifactShare < ApplicationRecord
  belongs_to :team
  belongs_to :blob, class_name: "ActiveStorage::Blob"
  belongs_to :created_by, class_name: "User"

  before_create { self.token ||= SecureRandom.urlsafe_base64(16) }

  # Idempotent: byte-identical artifacts de-dupe to one blob, so a second
  # share of the same content returns the existing row.
  def self.share_blob!(blob:, message:, user:)
    find_or_create_by!(blob: blob) do |share|
      share.team = message.conversation.team
      share.created_by = user
    end
  end

  def self.for_blob(blob)
    find_by(blob: blob)
  end
end
