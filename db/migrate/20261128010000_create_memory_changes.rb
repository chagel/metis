class CreateMemoryChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :memory_changes do |t|
      t.references :team, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :user_memory, foreign_key: { on_delete: :nullify }
      t.references :conversation, foreign_key: { on_delete: :nullify }
      t.integer :action, null: false
      t.integer :actor, null: false
      t.text :before
      t.text :after
      t.text :reason
      t.datetime :created_at, null: false
    end
    add_index :memory_changes, %i[team_id user_id created_at]

    add_reference :skills, :proposed_by, foreign_key: { to_table: :users, on_delete: :nullify }
  end
end
