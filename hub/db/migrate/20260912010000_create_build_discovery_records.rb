class CreateBuildDiscoveryRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :prototypes do |table|
      table.references :repository, null: false, index: true
      table.references :author, null: true, index: true
      table.string :branch_name, null: false
      table.timestamps

      table.index %i[repository_id branch_name], unique: true
      table.check_constraint "length(trim(branch_name)) BETWEEN 1 AND 255",
        name: "prototypes_branch_name"
    end
    add_foreign_key :prototypes, :repositories
    add_foreign_key :prototypes, :users, column: :author_id

    create_table :builds do |table|
      table.references :prototype, null: false, index: true
      table.integer :number, null: false
      table.string :commit_sha, null: false
      table.string :previous_commit_sha
      table.string :state, null: false, default: "queued"
      table.datetime :started_at
      table.datetime :finished_at
      table.timestamps

      table.index %i[prototype_id commit_sha], unique: true
      table.index %i[prototype_id number], unique: true
      table.check_constraint "number > 0", name: "builds_positive_number"
      table.check_constraint \
        "length(commit_sha) = 40 AND commit_sha NOT GLOB '*[^0-9a-f]*'",
        name: "builds_commit_sha"
      table.check_constraint \
        "previous_commit_sha IS NULL OR " \
          "(length(previous_commit_sha) = 40 AND previous_commit_sha NOT GLOB '*[^0-9a-f]*')",
        name: "builds_previous_commit_sha"
      table.check_constraint \
        "previous_commit_sha IS NULL OR previous_commit_sha <> commit_sha",
        name: "builds_distinct_commit_shas"
      table.check_constraint \
        "state IN ('queued', 'running', 'failed', 'superseded', 'successful')",
        name: "builds_state"
      table.check_constraint \
        "(state = 'queued' AND started_at IS NULL AND finished_at IS NULL) OR " \
          "(state = 'running' AND started_at IS NOT NULL AND finished_at IS NULL) OR " \
          "(state = 'superseded' AND started_at IS NULL AND finished_at IS NOT NULL) OR " \
          "(state IN ('failed', 'successful') AND started_at IS NOT NULL AND finished_at IS NOT NULL)",
        name: "builds_state_timestamps"
    end
    add_foreign_key :builds, :prototypes

    create_table :webhook_deliveries do |table|
      table.references :build, null: true, index: true
      table.string :github_delivery_id, null: false
      table.string :event, null: false
      table.string :payload_sha256, null: false
      table.datetime :processing_started_at
      table.datetime :processed_at
      table.timestamps

      table.index :github_delivery_id, unique: true
      table.check_constraint "length(trim(github_delivery_id)) BETWEEN 1 AND 255",
        name: "webhook_deliveries_github_id"
      table.check_constraint "length(trim(event)) BETWEEN 1 AND 100",
        name: "webhook_deliveries_event"
      table.check_constraint \
        "length(payload_sha256) = 64 AND payload_sha256 NOT GLOB '*[^0-9a-f]*'",
        name: "webhook_deliveries_payload_sha256"
      table.check_constraint \
        "processed_at IS NULL OR processing_started_at IS NULL",
        name: "webhook_deliveries_processing_state"
    end
    add_foreign_key :webhook_deliveries, :builds, on_delete: :nullify
  end
end
