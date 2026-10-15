class RemoveBuildSourceEvidence < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :builds, name: "builds_publication"
    remove_check_constraint :builds, name: "builds_manifest_sha256"
    remove_check_constraint :builds, name: "builds_source_bytes"
    remove_check_constraint :builds, name: "builds_source_sha256"
    remove_columns :builds, :manifest_sha256, :source_bytes, :source_sha256
    add_current_publication_constraint
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "removed source and manifest evidence cannot be reconstructed"
  end

  private

  def add_current_publication_constraint
    add_check_constraint \
      :builds,
      "(state = 'successful' AND workflow_completed_at IS NOT NULL AND " \
        "github_artifact_id IS NOT NULL AND artifact_prefix IS NOT NULL AND " \
        "artifact_bytes IS NOT NULL AND failure_summary IS NULL) OR " \
        "(state <> 'successful' AND artifact_prefix IS NULL AND artifact_bytes IS NULL)",
      name: "builds_publication"
  end
end
