class IndexMemorySignals < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :messages, :conversation_id, name: "index_messages_applying_memories",
      where: "cardinality(applied_memory_ids) > 0", algorithm: :concurrently
    add_index :messages, %i[conversation_id corrected_at], name: "index_messages_on_corrections",
      where: "corrected_at IS NOT NULL", algorithm: :concurrently
  end
end
