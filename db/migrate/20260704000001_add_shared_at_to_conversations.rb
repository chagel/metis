class AddSharedAtToConversations < ActiveRecord::Migration[8.1]
  def up
    add_column :conversations, :shared_at, :datetime

    # Backfill existing public links so the Sharing page has a stable
    # shared-at to order/label by (updated_at is the best proxy we have
    # for already-minted tokens).
    execute <<~SQL.squish
      UPDATE conversations SET shared_at = updated_at WHERE share_token IS NOT NULL
    SQL
  end

  def down
    remove_column :conversations, :shared_at
  end
end
