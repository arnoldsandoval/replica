# Records each time Hub looked for learnings in one repository: what Copilot read, what it
# suggested, and the usage Copilot reported, so administrators can see the work and its cost.
class CreateLearningRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :learning_runs do |t|
      t.references :repository, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :requested_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.boolean :scheduled, null: false, default: false
      t.string :state, null: false, default: "queued"
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :comments_considered, null: false, default: 0
      t.integer :comments_labeled, null: false, default: 0
      t.integer :comments_remaining, null: false, default: 0
      t.integer :suggestions, null: false, default: 0
      t.integer :suggestions_remaining, null: false, default: 0
      t.integer :copilot_requests, null: false, default: 0
      t.bigint :input_tokens, null: false, default: 0
      t.bigint :output_tokens, null: false, default: 0
      t.bigint :nano_aiu, null: false, default: 0
      t.string :models
      t.string :failure_code
      t.string :failure_summary
      t.timestamps
      t.index %i[repository_id created_at]
      t.index :created_at
      t.index \
        :repository_id,
        unique: true,
        where: "state IN ('queued', 'running')",
        name: "index_learning_runs_on_active_repository"
    end
    add_check_constraint \
      :learning_runs,
      "state IN ('queued', 'running', 'succeeded', 'failed')",
      name: "learning_runs_state"
    add_check_constraint \
      :learning_runs,
      "comments_considered >= 0 AND comments_labeled >= 0 AND comments_remaining >= 0 AND suggestions >= 0 " \
      "AND suggestions_remaining >= 0 AND copilot_requests >= 0 AND input_tokens >= 0 AND output_tokens >= 0 AND nano_aiu >= 0",
      name: "learning_runs_counts"
  end
end
