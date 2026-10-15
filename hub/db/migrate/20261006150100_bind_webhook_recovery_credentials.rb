class BindWebhookRecoveryCredentials < ActiveRecord::Migration[8.1]
  def change
    add_column :webhook_recovery_checkpoints, :credential_revision, :bigint, null: false, default: 1
    add_column :webhook_redeliveries, :credential_revision, :bigint, null: false, default: 1
    add_check_constraint :webhook_recovery_checkpoints, "credential_revision > 0",
      name: "webhook_recovery_revision"
    add_check_constraint :webhook_redeliveries, "credential_revision > 0",
      name: "webhook_redelivery_revision"
  end
end
