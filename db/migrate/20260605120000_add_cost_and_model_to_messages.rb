class AddCostAndModelToMessages < ActiveRecord::Migration[8.1]
  def change
    # pi reports a per-message cost in USD (get_session_stats / each
    # assistant message's usage.cost.total). decimal, not float, so summing
    # a conversation's cost is exact.
    add_column :messages, :cost, :decimal, precision: 12, scale: 6

    # The model that served this turn, snapshotted per message so historical
    # usage stays correctly attributed when a conversation switches models
    # mid-thread (Conversation#agent_model only holds the latest).
    add_column :messages, :model_key, :string
  end
end
