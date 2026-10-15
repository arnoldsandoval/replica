class ExtendConversationNotifications < ActiveRecord::Migration[8.1]
  def up
    add_column :notifications, :source_key, :string
    execute "UPDATE notifications SET source_key = 'mention/' || comment_mention_id"
    change_column_null :notifications, :source_key, false
    change_column_null :notifications, :comment_mention_id, true
    remove_check_constraint :notifications, name: "notifications_kind"
    add_check_constraint :notifications,
      "kind IN ('comment_mention', 'comment_reply', 'comment_reaction', 'thread_resolved', 'thread_reopened')",
      name: "notifications_kind"
    add_check_constraint :notifications,
      "(kind = 'comment_mention' AND comment_mention_id IS NOT NULL) OR (kind <> 'comment_mention' AND comment_mention_id IS NULL)",
      name: "notifications_mention_source"
    add_index :notifications, %i[recipient_id source_key], unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Conversation activity notifications cannot be converted to mentions"
  end
end
