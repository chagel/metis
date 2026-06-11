class AddReliabilityToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :last_reported_at, :datetime
    add_column :tasks, :reclaims_count, :integer, default: 0, null: false
  end
end
