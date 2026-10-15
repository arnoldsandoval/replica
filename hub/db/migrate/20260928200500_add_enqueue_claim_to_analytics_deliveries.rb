class AddEnqueueClaimToAnalyticsDeliveries < ActiveRecord::Migration[8.1]
  def change
    add_column :analytics_deliveries, :enqueue_claim_expires_at, :datetime
  end
end
