class CreateWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_events do |t|
      t.references :team, null: false, foreign_key: true
      t.references :project, foreign_key: true
      t.integer :provider, null: false
      t.string :event_type, null: false
      t.string :external_id
      t.string :source_installation_id
      t.jsonb :payload, default: {}, null: false

      t.timestamps
    end

    # Idempotency against provider redeliveries — one row per delivery.
    add_index :webhook_events, [ :provider, :external_id ], unique: true,
              where: "external_id IS NOT NULL"
  end
end
