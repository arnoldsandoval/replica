# Keeps scan coverage conservative and makes hourly history cleanup indexed.
class AddWebhookRecoveryCoverageAndRetentionIndexes < ActiveRecord::Migration[8.1]
  def change
    add_column :webhook_recovery_checkpoints, :last_completed_scan_started_at, :datetime
    add_column :webhook_recovery_checkpoints, :last_completed_credential_revision, :bigint
    add_index :webhook_deliveries, :created_at
    add_index :webhook_redeliveries, %i[state updated_at]
    add_index :webhook_recovery_checkpoints, :updated_at
  end
end
