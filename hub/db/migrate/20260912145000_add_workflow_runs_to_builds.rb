class AddWorkflowRunsToBuilds < ActiveRecord::Migration[8.1]
  def change
    change_table :builds, bulk: true do |table|
      table.bigint :github_workflow_run_id
      table.integer :github_workflow_run_attempt
      table.string :workflow_url, limit: 2048
      table.string :failure_summary
    end

    add_index \
      :builds,
      %i[github_workflow_run_id github_workflow_run_attempt],
      unique: true,
      where: "github_workflow_run_id IS NOT NULL",
      name: "index_builds_on_github_workflow_run"
    add_check_constraint \
      :builds,
      "CASE WHEN github_workflow_run_id IS NULL THEN " \
        "github_workflow_run_attempt IS NULL AND workflow_url IS NULL " \
        "ELSE github_workflow_run_attempt > 0 AND " \
        "COALESCE(length(trim(workflow_url)) BETWEEN 1 AND 2048, 0) END",
      name: "builds_workflow_identity"
    add_check_constraint \
      :builds,
      "failure_summary IS NULL OR " \
        "(state = 'failed' AND length(CAST(failure_summary AS BLOB)) BETWEEN 1 AND 1000)",
      name: "builds_failure_summary"
  end
end
