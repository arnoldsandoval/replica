class IndexWebhookRecoveryIdentity < ActiveRecord::Migration[8.1]
  def change
    add_index :webhook_redeliveries, :github_delivery_id
  end
end
