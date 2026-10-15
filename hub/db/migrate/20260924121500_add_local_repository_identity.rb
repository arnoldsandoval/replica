class AddLocalRepositoryIdentity < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :local_identity, :string
    remove_index :repositories, :local_path
    add_index :repositories, :local_path, unique: true,
      where: "installation_state = 'active'", name: "index_active_repositories_on_local_path"
    add_index :repositories, [ :local_path, :local_identity ], unique: true,
      name: "index_repositories_on_local_path_and_identity"
    add_check_constraint :repositories, "local_identity IS NULL OR local_path IS NOT NULL",
      name: "repositories_local_identity"
  end
end
