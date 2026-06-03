class AddStarredAtToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :starred_at, :datetime
    add_index :conversations, :starred_at
  end
end
