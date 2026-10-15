class MarkReplicaBuildOwners < ActiveRecord::Migration[8.1]
  def up
    add_column :prototypes, :replica, :boolean, default: false, null: false
    execute <<~SQL
      UPDATE prototypes SET replica = 1, registered_at = NULL
      WHERE branch_name = (
        SELECT default_branch FROM repositories WHERE repositories.id = prototypes.repository_id
      )
    SQL
    add_check_constraint :prototypes, "replica = 0 OR registered_at IS NULL",
      name: "prototypes_replica_unregistered"
  end

  def down
    remove_check_constraint :prototypes, name: "prototypes_replica_unregistered"
    remove_column :prototypes, :replica
  end
end
