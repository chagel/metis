class AddSenderToMessages < ActiveRecord::Migration[8.1]
  def change
    add_reference :messages, :sender, foreign_key: { to_table: :users, on_delete: :nullify }
  end
end
