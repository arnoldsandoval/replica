class AddLocalDevelopmentIdentity < ActiveRecord::Migration[8.1]
  def change
    change_column_null :repositories, :github_id, true
    add_column :repositories, :local_path, :string
    add_index :repositories, :local_path, unique: true
    remove_check_constraint :repositories, name: "repositories_positive_github_id"
    add_check_constraint :repositories,
      "(github_id IS NOT NULL AND github_id > 0 AND local_path IS NULL) OR " \
        "(github_id IS NULL AND local_path IS NOT NULL AND length(trim(local_path)) > 0)",
      name: "repositories_source_identity"

    change_column_null :users, :github_id, true
    remove_check_constraint :users, name: "users_positive_github_id"
    add_check_constraint :users, "github_id IS NULL OR github_id > 0",
      name: "users_positive_github_id"
    add_index :users, "(github_id IS NULL)", unique: true,
      where: "github_id IS NULL", name: "index_users_on_one_local_identity"

    remove_check_constraint :builds, name: "builds_publication"
    add_check_constraint :builds,
      "(state = 'successful' AND artifact_prefix IS NOT NULL AND artifact_bytes IS NOT NULL " \
        "AND failure_summary IS NULL AND " \
        "((workflow_completed_at IS NOT NULL AND github_artifact_id IS NOT NULL) OR " \
        "(workflow_completed_at IS NULL AND github_artifact_id IS NULL))) OR " \
        "(state <> 'successful' AND artifact_prefix IS NULL AND artifact_bytes IS NULL)",
      name: "builds_publication"
  end
end
