class BackfillTeamVisibilityForShared < ActiveRecord::Migration[8.1]
  # The share token used to imply in-app team access; now visibility alone
  # governs it. Keep existing shared chats team-readable.
  def up
    execute "UPDATE conversations SET visibility = 1 WHERE share_token IS NOT NULL"
  end

  def down
  end
end
