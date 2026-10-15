class TrackLocalPackageCompletion < ActiveRecord::Migration[8.1]
  def change
    add_column :builds, :local_package_completed_at, :datetime
    remove_check_constraint :builds, name: "builds_publication"
    add_check_constraint :builds,
      "(state = 'successful' AND artifact_prefix IS NOT NULL AND artifact_bytes IS NOT NULL " \
        "AND failure_summary IS NULL AND " \
        "((workflow_completed_at IS NOT NULL AND github_artifact_id IS NOT NULL " \
        "AND local_package_completed_at IS NULL) OR " \
        "(workflow_completed_at IS NULL AND github_artifact_id IS NULL " \
        "AND local_package_completed_at IS NOT NULL))) OR " \
        "(state <> 'successful' AND artifact_prefix IS NULL AND artifact_bytes IS NULL " \
        "AND local_package_completed_at IS NULL)",
      name: "builds_publication"
  end
end
