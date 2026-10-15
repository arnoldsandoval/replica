class AddChronologicalOrderingToBuilds < ActiveRecord::Migration[8.1]
  def change
    add_column :builds, :workflow_created_at, :datetime
    add_reference \
      :prototypes,
      :current_build,
      foreign_key: false
    add_foreign_key \
      :prototypes,
      :builds,
      column: %i[current_build_id id],
      primary_key: %i[id prototype_id],
      on_delete: :restrict,
      name: "fk_prototypes_current_build"
    add_check_constraint \
      :builds,
      "workflow_created_at IS NULL OR github_workflow_run_id IS NOT NULL",
      name: "builds_workflow_creation"
    add_index \
      :builds,
      "prototype_id, COALESCE(workflow_created_at, created_at) DESC, number DESC",
      name: "index_builds_on_prototype_and_chronology"
  end
end
