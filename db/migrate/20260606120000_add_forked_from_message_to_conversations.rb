class AddForkedFromMessageToConversations < ActiveRecord::Migration[8.1]
  def change
    # A fork records the source message it branched from. Nullify on delete so
    # destroying the source conversation (which cascade-deletes its messages)
    # leaves the fork standing, just without provenance.
    add_reference :conversations, :forked_from_message,
                  foreign_key: { to_table: :messages, on_delete: :nullify },
                  null: true

    # True between a fork's creation and its first turn, when that turn still
    # owes a real copy of the source's pi session (host-backed runtimes only).
    # ForkPreparer clears it; a cloud-source fork is never set and instead
    # replays history. See Agent::ForkPreparer / Conversation#needs_history_replay?.
    add_column :conversations, :fork_pending, :boolean, default: false, null: false
  end
end
