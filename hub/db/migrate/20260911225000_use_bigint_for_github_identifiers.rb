class UseBigintForGithubIdentifiers < ActiveRecord::Migration[8.1]
  def change
    change_column :github_app_configurations, :github_app_id, :bigint, null: false
    change_column :github_app_configurations, :owner_github_id, :bigint, null: false
    change_column :github_app_configurations, :installation_id, :bigint
  end
end
