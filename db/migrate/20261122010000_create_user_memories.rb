class CreateUserMemories < ActiveRecord::Migration[8.1]
  def change
    create_table :user_memories do |t|
      t.references :team, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :source_conversation, foreign_key: { to_table: :conversations, on_delete: :nullify }
      t.text :content, null: false
      t.integer :kind, null: false
      t.integer :source, null: false, default: 1
      t.integer :confidence, null: false, default: 0
      t.datetime :last_applied_at
      t.timestamps
    end
    add_index :user_memories, %i[team_id user_id kind]
  end
end
