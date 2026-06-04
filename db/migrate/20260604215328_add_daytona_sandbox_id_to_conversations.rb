class AddDaytonaSandboxIdToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :daytona_sandbox_id, :string
    add_index :conversations, :daytona_sandbox_id
  end
end
