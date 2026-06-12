class AddClaimedAtToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :claimed_at, :datetime
  end
end
