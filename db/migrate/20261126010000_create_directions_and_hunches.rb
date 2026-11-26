class CreateDirectionsAndHunches < ActiveRecord::Migration[8.1]
  def change
    create_table :directions do |t|
      t.references :team, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :title, null: false
      t.text :brief
      t.text :view
      t.jsonb :open_questions, null: false, default: []
      t.integer :status, null: false, default: 0
      t.datetime :last_explored_at
      t.timestamps
    end
    add_index :directions, %i[team_id user_id status]

    create_table :hunches do |t|
      t.references :team, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :direction, foreign_key: { on_delete: :nullify }
      t.references :source_memory, foreign_key: { to_table: :user_memories, on_delete: :nullify }
      t.references :conversation, foreign_key: { on_delete: :nullify }
      t.string :title, null: false
      t.text :body, null: false
      t.text :why_now
      t.jsonb :evidence, null: false, default: []
      t.integer :impact, null: false, default: 1
      t.integer :confidence, null: false, default: 1
      t.integer :status, null: false, default: 0
      t.datetime :outcome_at
      t.text :dismiss_reason
      t.timestamps
    end
    add_index :hunches, %i[team_id user_id status created_at]
  end
end
