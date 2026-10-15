class CreateGithubAppConfigurations < ActiveRecord::Migration[8.1]
  def change
    create_table :github_app_configurations do |table|
      table.integer :singleton_key, null: false, default: 1
      table.integer :github_app_id, null: false
      table.string :client_id, null: false
      table.text :client_secret, null: false
      table.text :webhook_secret, null: false
      table.text :private_key, null: false
      table.integer :owner_github_id, null: false
      table.string :owner_login, null: false
      table.string :owner_type, null: false
      table.integer :installation_id
      table.string :installation_state, null: false, default: "not_installed"
      table.datetime :installed_at
      table.datetime :suspended_at
      table.datetime :last_reconciled_at
      table.string :app_slug, null: false

      table.timestamps
    end

    add_index :github_app_configurations, :singleton_key, unique: true
    add_check_constraint \
      :github_app_configurations, "singleton_key = 1",
      name: "github_app_configurations_singleton"
    add_check_constraint \
      :github_app_configurations, "github_app_id > 0",
      name: "github_app_configurations_positive_app_id"
    add_check_constraint \
      :github_app_configurations, "owner_github_id > 0",
      name: "github_app_configurations_positive_owner_id"
    add_check_constraint \
      :github_app_configurations,
      "installation_id IS NULL OR installation_id > 0",
      name: "github_app_configurations_positive_installation_id"
    add_check_constraint \
      :github_app_configurations,
      "owner_type IN ('Organization', 'User')",
      name: "github_app_configurations_owner_type"
    add_check_constraint \
      :github_app_configurations,
      "installation_state IN ('not_installed', 'active', 'suspended', 'removed')",
      name: "github_app_configurations_installation_state"
    add_check_constraint \
      :github_app_configurations,
      <<~SQL.squish,
        (installation_state = 'not_installed' AND installation_id IS NULL) OR
        (installation_state <> 'not_installed' AND installation_id IS NOT NULL)
      SQL
      name: "github_app_configurations_installation_identity"
  end
end
