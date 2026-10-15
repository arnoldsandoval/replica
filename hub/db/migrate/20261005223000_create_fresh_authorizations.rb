class CreateFreshAuthorizations < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :fresh_authorized_at, :datetime
    add_column :canvas_grants, :fresh_authorized_at, :datetime

    create_table :fresh_authorizations do |t|
      t.string :public_id, null: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :repository, foreign_key: { on_delete: :nullify }
      t.bigint :github_id, null: false
      t.string :credential_type, null: false
      t.bigint :credential_id, null: false
      t.string :purpose, null: false
      t.string :return_to, null: false
      t.string :oauth_state_digest
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.datetime :verified_at
      t.timestamps
      t.index :public_id, unique: true
      t.index [ :credential_type, :credential_id ]
      t.index :expires_at
    end
    add_check_constraint :fresh_authorizations,
      "credential_type IN ('Session', 'CanvasGrant') AND credential_id > 0 AND github_id > 0",
      name: "fresh_authorizations_identity"
    add_check_constraint :fresh_authorizations,
      "purpose IN ('never_expiring_share', 'analytics_destination', 'hub_admin_management', " \
      "'sharing_settings', 'session_revocation', 'github_app_reset', 'github_app_credentials', " \
      "'github_app_webhook', 'github_app_finish_webhook')", name: "fresh_authorizations_purpose"
    add_check_constraint :fresh_authorizations,
      "verified_at IS NULL OR consumed_at IS NOT NULL", name: "fresh_authorizations_verification"
  end
end
