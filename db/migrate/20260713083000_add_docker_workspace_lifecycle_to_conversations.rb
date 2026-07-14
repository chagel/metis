class AddDockerWorkspaceLifecycleToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :docker_workspace_last_used_at, :datetime
    add_column :conversations, :docker_workspace_evicted_at, :datetime
    add_column :conversations, :docker_workspace_eviction_reason, :string
  end
end
