class AddVisibilityToConversations < ActiveRecord::Migration[8.1]
  def change
    # personal(0) | team(1). Team visibility is in-app only — the public
    # share link stays a separate, explicit owner action (share_token).
    add_column :conversations, :visibility, :integer, null: false, default: 0
  end
end
