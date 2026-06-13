class AddAutoClaimTasksToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :auto_claim_tasks, :boolean, default: true, null: false
    add_column :users, :bridge_token_hint, :string
  end
end
