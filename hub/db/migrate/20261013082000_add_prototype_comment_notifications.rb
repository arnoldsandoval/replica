class AddPrototypeCommentNotifications < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :notifications, name: "notifications_kind"
    add_check_constraint \
      :notifications,
      "kind IN ('comment_created', 'comment_mention', 'comment_reply', 'comment_reaction', 'thread_resolved', 'thread_reopened')",
      name: "notifications_kind"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Prototype comment notifications cannot be converted to other activities"
  end
end
