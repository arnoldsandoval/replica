class CreateWebhookRecoveryMetadata < ActiveRecord::Migration[8.1]
  def change
    add_column :webhook_deliveries, :processing_token, :string

    create_table :webhook_redeliveries do |t|
      # Keep evidence when an operator replaces or removes the App.
      t.bigint :github_app_configuration_id, null: false
      t.bigint :github_app_id, null: false
      t.string :github_delivery_id, null: false
      t.bigint :github_attempt_id
      t.bigint :installation_id
      t.string :event, null: false
      t.string :state, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :first_delivered_at, null: false
      t.datetime :due_at, null: false
      t.datetime :expires_at, null: false
      t.string :failure_code
      t.string :lease_token
      t.timestamps
    end
    add_index :webhook_redeliveries, %i[github_app_configuration_id github_delivery_id],
      unique: true, name: :index_webhook_redeliveries_on_app_and_guid
    add_index :webhook_redeliveries, %i[state due_at]
    add_check_constraint :webhook_redeliveries,
      "state IN ('pending', 'requesting', 'waiting', 'succeeded', 'failed')", name: :webhook_redelivery_state
    add_check_constraint :webhook_redeliveries, "attempts BETWEEN 0 AND 12", name: :webhook_redelivery_attempts
    add_check_constraint :webhook_redeliveries,
      "github_app_configuration_id > 0 AND github_app_id > 0", name: :webhook_redelivery_app
    add_check_constraint :webhook_redeliveries,
      "github_attempt_id IS NULL OR github_attempt_id > 0", name: :webhook_redelivery_attempt_id
    add_check_constraint :webhook_redeliveries,
      "installation_id IS NULL OR installation_id > 0", name: :webhook_redelivery_installation
    add_check_constraint :webhook_redeliveries,
      "length(trim(github_delivery_id)) BETWEEN 1 AND 255", name: :webhook_redelivery_guid
    add_check_constraint :webhook_redeliveries,
      "event IN ('push', 'workflow_run', 'installation', 'installation_repositories')", name: :webhook_redelivery_event
    add_check_constraint :webhook_redeliveries,
      "expires_at > first_delivered_at", name: :webhook_redelivery_window

    create_table :webhook_recovery_checkpoints do |t|
      t.bigint :github_app_configuration_id, null: false
      t.bigint :github_app_id, null: false
      t.string :cursor, limit: 2048
      t.integer :pages, null: false, default: 0
      t.datetime :scan_started_at
      t.datetime :last_completed_at
      t.datetime :gap_started_at
      t.datetime :gap_ended_at
      t.datetime :due_at, null: false
      t.datetime :enqueue_claim_expires_at
      t.string :lease_token
      t.integer :failures, null: false, default: 0
      t.string :failure_code
      t.timestamps
    end
    add_index :webhook_recovery_checkpoints, :github_app_configuration_id, unique: true
    add_check_constraint :webhook_recovery_checkpoints,
      "github_app_configuration_id > 0 AND github_app_id > 0", name: :webhook_recovery_app
    add_check_constraint :webhook_recovery_checkpoints,
      "pages >= 0 AND failures >= 0", name: :webhook_recovery_counters
  end
end
