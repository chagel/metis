class CreateArtifactShares < ActiveRecord::Migration[8.1]
  def change
    create_table :artifact_shares do |t|
      t.references :team, null: false, foreign_key: true
      # Purging the blob cascades the share away — the link 404s.
      t.references :blob, null: false, index: { unique: true },
                   foreign_key: { to_table: :active_storage_blobs, on_delete: :cascade }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :token, null: false, index: { unique: true }

      t.timestamps
    end
  end
end
