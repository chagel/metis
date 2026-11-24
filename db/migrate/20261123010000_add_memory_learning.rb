class AddMemoryLearning < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :applied_memory_ids, :bigint, array: true, default: [], null: false
    add_column :messages, :corrected_at, :datetime
    add_column :messages, :correction_note, :text
    add_column :user_memories, :edited_by_user_at, :datetime
    add_column :memberships, :memory_deletions, :jsonb, default: [], null: false
  end
end
