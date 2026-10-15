class AddPrototypeRetirement < ActiveRecord::Migration[8.1]
  def change
    add_column :prototypes, :branch_deleted_at, :datetime
    add_column :prototypes, :retired_head_sha, :string
    remove_index :prototypes, [ :repository_id, :branch_name ], unique: true
    add_index :prototypes, [ :repository_id, :branch_name ], unique: true,
      where: "branch_deleted_at IS NULL", name: "index_prototypes_on_active_branch"
    add_index :prototypes, [ :repository_id, :branch_name, :branch_deleted_at ]
    add_check_constraint :prototypes,
      "retired_head_sha IS NULL OR (branch_deleted_at IS NOT NULL AND " \
        "length(retired_head_sha) = 40 AND retired_head_sha NOT GLOB '*[^0-9a-f]*')",
      name: "prototypes_retired_head"
  end
end
