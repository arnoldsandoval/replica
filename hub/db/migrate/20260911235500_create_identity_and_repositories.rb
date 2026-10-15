class CreateIdentityAndRepositories < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |table|
      table.bigint :github_id, null: false
      table.string :login, null: false
      table.string :name
      table.string :avatar_url
      table.datetime :last_authenticated_at, null: false
      table.timestamps

      table.index :github_id, unique: true
      table.check_constraint "github_id > 0", name: "users_positive_github_id"
      table.check_constraint "length(trim(login)) > 0", name: "users_login_present"
    end

    create_table :repositories do |table|
      table.bigint :github_id, null: false
      table.string :name_with_owner, null: false
      table.string :default_branch, null: false
      table.string :installation_state, null: false, default: "active"
      table.datetime :synchronized_at, null: false
      table.datetime :removed_at
      table.timestamps

      table.index :github_id, unique: true
      table.check_constraint "github_id > 0", name: "repositories_positive_github_id"
      table.check_constraint "length(trim(name_with_owner)) > 0", name: "repositories_name_present"
      table.check_constraint "length(trim(default_branch)) > 0", name: "repositories_default_branch_present"
      table.check_constraint \
        "installation_state IN ('active', 'removed')",
        name: "repositories_installation_state"
      table.check_constraint \
        "(installation_state = 'active' AND removed_at IS NULL) OR " \
          "(installation_state = 'removed' AND removed_at IS NOT NULL)",
        name: "repositories_removal_state"
    end

    create_table :sessions do |table|
      table.references :user, null: false, index: true
      table.string :ip_address
      table.string :user_agent
      table.timestamps
    end
    add_foreign_key :sessions, :users, on_delete: :cascade
  end
end
