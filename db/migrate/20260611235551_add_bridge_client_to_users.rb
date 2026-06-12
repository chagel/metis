class AddBridgeClientToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :bridge_client, :string
  end
end
