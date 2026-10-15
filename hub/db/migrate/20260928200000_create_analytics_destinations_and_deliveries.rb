class CreateAnalyticsDestinationsAndDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :analytics_destinations do |table|
      table.references :repository, null: false, foreign_key: true
      table.string :provider, null: false
      table.string :region, null: false
      table.text :credentials, null: false
      table.json :event_types, null: false
      table.boolean :enabled, null: false, default: true
      table.datetime :last_delivered_at
      table.timestamps
    end
    add_index :analytics_destinations, [ :repository_id, :provider ], unique: true
    add_index :analytics_destinations, [ :id, :repository_id ], unique: true
    add_check_constraint :analytics_destinations,
      "provider IN ('segment', 'mixpanel')", name: "analytics_destination_provider"
    add_check_constraint :analytics_destinations,
      "(provider = 'segment' AND region IN ('us', 'eu')) OR " \
        "(provider = 'mixpanel' AND region IN ('us', 'eu', 'in'))",
      name: "analytics_destination_region"

    create_table :analytics_deliveries do |table|
      table.references :repository, null: false, foreign_key: true
      table.bigint :event_id, null: false
      table.bigint :destination_id, null: false
      table.string :state, null: false, default: "pending"
      table.integer :attempts, null: false, default: 0
      table.datetime :due_at, null: false
      table.string :lease_token
      table.string :failure_code
      table.datetime :delivered_at
      table.timestamps
    end
    add_index :analytics_deliveries, [ :event_id, :destination_id ], unique: true
    add_index :analytics_deliveries, [ :state, :due_at ]
    add_foreign_key :analytics_deliveries, :analytics_events,
      column: [ :event_id, :repository_id ], primary_key: [ :id, :repository_id ], on_delete: :cascade
    add_foreign_key :analytics_deliveries, :analytics_destinations,
      column: [ :destination_id, :repository_id ], primary_key: [ :id, :repository_id ], on_delete: :cascade
    add_check_constraint :analytics_deliveries,
      "state IN ('pending', 'delivering', 'retryable', 'succeeded', 'failed', 'canceled')",
      name: "analytics_delivery_state"
    add_check_constraint :analytics_deliveries, "attempts >= 0", name: "analytics_delivery_attempts"
  end
end
