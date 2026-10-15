class AddBuildImportState < ActiveRecord::Migration[8.1]
  def change
    change_table :builds, bulk: true do |table|
      table.datetime :workflow_completed_at
      table.bigint :github_artifact_id
      table.string :artifact_prefix
      table.bigint :artifact_bytes
      table.string :manifest_sha256, limit: 64
      table.bigint :source_bytes
      table.string :source_sha256, limit: 64
    end

    add_index :builds, :github_artifact_id, unique: true, where: "github_artifact_id IS NOT NULL"
    add_index :builds, :artifact_prefix, unique: true, where: "artifact_prefix IS NOT NULL"
    remove_check_constraint \
      :builds,
      "CASE WHEN github_workflow_run_id IS NULL THEN " \
        "github_workflow_run_attempt IS NULL AND workflow_url IS NULL " \
        "ELSE github_workflow_run_attempt > 0 AND " \
        "COALESCE(length(trim(workflow_url)) BETWEEN 1 AND 2048, 0) END",
      name: "builds_workflow_identity"
    add_check_constraint \
      :builds,
      "CASE WHEN github_workflow_run_id IS NULL THEN " \
        "github_workflow_run_attempt IS NULL AND workflow_url IS NULL " \
        "ELSE github_workflow_run_id > 0 AND github_workflow_run_attempt > 0 AND " \
        "COALESCE(length(trim(workflow_url)) BETWEEN 1 AND 2048, 0) END",
      name: "builds_workflow_identity"
    add_check_constraint \
      :builds,
      "workflow_completed_at IS NULL OR " \
        "(github_workflow_run_id IS NOT NULL AND state IN ('running', 'failed', 'successful'))",
      name: "builds_workflow_completion"
    add_check_constraint \
      :builds,
      "github_artifact_id IS NULL OR " \
        "(github_artifact_id > 0 AND workflow_completed_at IS NOT NULL)",
      name: "builds_github_artifact"
    add_check_constraint \
      :builds,
      "artifact_prefix IS NULL OR artifact_prefix = 'builds/' || id",
      name: "builds_artifact_prefix"
    add_check_constraint \
      :builds,
      "artifact_bytes IS NULL OR artifact_bytes > 0",
      name: "builds_artifact_bytes"
    add_check_constraint \
      :builds,
      "source_bytes IS NULL OR source_bytes > 0",
      name: "builds_source_bytes"
    add_check_constraint \
      :builds,
      "manifest_sha256 IS NULL OR " \
        "(length(manifest_sha256) = 64 AND manifest_sha256 NOT GLOB '*[^0-9a-f]*')",
      name: "builds_manifest_sha256"
    add_check_constraint \
      :builds,
      "source_sha256 IS NULL OR " \
        "(length(source_sha256) = 64 AND source_sha256 NOT GLOB '*[^0-9a-f]*')",
      name: "builds_source_sha256"
    add_check_constraint \
      :builds,
      "(state = 'successful' AND workflow_completed_at IS NOT NULL AND " \
        "github_artifact_id IS NOT NULL AND artifact_prefix IS NOT NULL AND " \
        "artifact_bytes IS NOT NULL AND manifest_sha256 IS NOT NULL AND " \
        "source_bytes IS NOT NULL AND source_sha256 IS NOT NULL AND failure_summary IS NULL) OR " \
        "(state <> 'successful' AND artifact_prefix IS NULL AND artifact_bytes IS NULL AND " \
        "manifest_sha256 IS NULL AND source_bytes IS NULL AND source_sha256 IS NULL)",
      name: "builds_publication"
  end
end
