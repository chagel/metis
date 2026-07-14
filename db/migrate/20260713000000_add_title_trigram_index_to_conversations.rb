class AddTitleTrigramIndexToConversations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :conversations, :title,
              name: "index_conversations_on_title_trigram",
              using: :gin, opclass: :gin_trgm_ops,
              algorithm: :concurrently
  end
end
