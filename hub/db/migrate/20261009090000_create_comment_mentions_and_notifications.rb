class CreateCommentMentionsAndNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :github_identities do |table|
      table.bigint :github_id, null: false
      table.string :login, null: false
      table.string :avatar_url
      table.timestamps
      table.index :github_id, unique: true
      table.check_constraint "github_id > 0", name: "github_identities_positive_id"
      table.check_constraint "length(trim(login)) > 0", name: "github_identities_login"
    end

    create_table :comment_mentions do |table|
      table.references :review_comment, null: false, foreign_key: { on_delete: :cascade }
      table.references :github_identity, null: false, foreign_key: { on_delete: :restrict }
      table.string :login, null: false
      table.timestamps
      table.index %i[review_comment_id github_identity_id], unique: true
      table.check_constraint "length(trim(login)) > 0", name: "comment_mentions_login"
    end

    create_table :notifications do |table|
      table.references :recipient, null: false, foreign_key: { to_table: :github_identities, on_delete: :restrict }
      table.references :actor, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      table.references :comment_mention, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      table.string :kind, null: false
      table.datetime :read_at
      table.integer :lock_version, null: false, default: 0
      table.timestamps
      table.index %i[recipient_id created_at id]
      table.check_constraint "kind = 'comment_mention'", name: "notifications_kind"
      table.check_constraint "lock_version >= 0", name: "notifications_version"
    end

    create_table :notification_resources do |table|
      table.references :notification, null: false, foreign_key: { on_delete: :cascade }
      table.references :resource, polymorphic: true, null: false
      table.string :role, null: false
      table.timestamps
      table.index %i[notification_id resource_type resource_id role], unique: true, name: "index_notification_resources_on_identity"
      table.check_constraint "role IN ('primary', 'context')", name: "notification_resources_role"
    end
  end
end
