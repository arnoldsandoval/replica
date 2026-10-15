# Existing overlap needs an acknowledged retry, not an assumed successful update.
class AddGithubAppAdministration < ActiveRecord::Migration[8.1]
  def up
    add_column :github_app_configurations, :lock_version, :integer, null: false, default: 0
    add_column :github_app_configurations, :credential_revision, :bigint, null: false, default: 1
    add_column :github_app_configurations, :webhook_rotation_state, :string, null: false, default: "idle"
    add_column :github_app_configurations, :webhook_request_token, :string
    add_column :github_app_configurations, :webhook_request_expires_at, :datetime
    execute <<~SQL
      UPDATE github_app_configurations
      SET webhook_rotation_state = 'pending'
      WHERE previous_webhook_secret IS NOT NULL
    SQL
    add_check_constraint :github_app_configurations,
      "credential_revision > 0 AND lock_version >= 0",
      name: "github_app_configurations_revision"
    add_check_constraint :github_app_configurations,
      "(webhook_rotation_state = 'idle' AND previous_webhook_secret IS NULL) OR " \
        "(webhook_rotation_state IN ('pending', 'confirmed') AND previous_webhook_secret IS NOT NULL)",
      name: "github_app_configurations_webhook_rotation"
    add_check_constraint :github_app_configurations,
      "(webhook_request_token IS NULL AND webhook_request_expires_at IS NULL) OR " \
        "(webhook_rotation_state = 'pending' AND webhook_request_token IS NOT NULL " \
        "AND webhook_request_expires_at IS NOT NULL)",
      name: "github_app_configurations_webhook_request"
  end

  def down
    remove_check_constraint :github_app_configurations, name: "github_app_configurations_webhook_request"
    remove_check_constraint :github_app_configurations, name: "github_app_configurations_webhook_rotation"
    remove_check_constraint :github_app_configurations, name: "github_app_configurations_revision"
    remove_column :github_app_configurations, :webhook_request_expires_at
    remove_column :github_app_configurations, :webhook_request_token
    remove_column :github_app_configurations, :webhook_rotation_state
    remove_column :github_app_configurations, :credential_revision
    remove_column :github_app_configurations, :lock_version
  end
end
