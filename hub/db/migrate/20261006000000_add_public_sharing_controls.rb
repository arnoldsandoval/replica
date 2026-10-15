class AddPublicSharingControls < ActiveRecord::Migration[8.1]
  def up
    create_table :sharing_settings do |t|
      t.boolean :public_sharing_enabled, null: false, default: false
      t.integer :revision, null: false, default: 0
      t.timestamps
      t.check_constraint "id = 1", name: "sharing_settings_singleton"
      t.check_constraint "revision >= 0", name: "sharing_settings_revision"
    end
    add_column :share_links, :revoked_at, :datetime
    execute "UPDATE share_links SET revoked_at = CURRENT_TIMESTAMP"
    execute "DELETE FROM share_preview_grants"
    create_table :share_link_creator_revocations do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :revision, null: false, default: 0
      t.timestamps
      t.index [ :repository_id, :user_id ], unique: true
      t.check_constraint "revision >= 0", name: "share_link_creator_revocations_revision"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "An upgrade permanently revokes existing public links"
  end
end
