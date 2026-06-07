class AddForkedFromMessageToConversations < ActiveRecord::Migration[8.1]
  def change
    # Nullify on delete so destroying the source (which cascades its messages)
    # leaves the fork standing, just without provenance.
    add_reference :conversations, :forked_from_message,
                  foreign_key: { to_table: :messages, on_delete: :nullify },
                  null: true

    # A host-backed fork still owing its first-turn session copy (ForkPreparer).
    add_column :conversations, :fork_pending, :boolean, default: false, null: false
  end
end
