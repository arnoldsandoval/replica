class AddWebhookRotationToGithubAppConfigurations < ActiveRecord::Migration[8.1]
  def change
    add_column :github_app_configurations, :previous_webhook_secret, :text
    add_column :github_app_configurations, :webhook_secret_rotated_at, :datetime
  end
end
