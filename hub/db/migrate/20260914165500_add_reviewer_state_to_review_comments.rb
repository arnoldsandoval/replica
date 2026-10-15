class AddReviewerStateToReviewComments < ActiveRecord::Migration[8.1]
  def change
    add_column :review_comments, :activity_version, :integer

    reversible do |direction|
      direction.up do
        execute "UPDATE review_comments SET activity_version = 1 WHERE root_id IS NULL"
      end
    end

    add_check_constraint \
      :review_comments,
      "(root_id IS NULL AND activity_version IS NOT NULL AND activity_version > 0) OR " \
        "(root_id IS NOT NULL AND activity_version IS NULL)",
      name: "review_comments_activity_version"

    create_table :review_comment_reactions do |table|
      table.references \
        :review_comment,
        null: false,
        foreign_key: { on_delete: :cascade }
      table.references \
        :user,
        null: false,
        foreign_key: { on_delete: :restrict }
      table.string :content, null: false
      table.timestamps

      table.index \
        %i[review_comment_id user_id content],
        unique: true,
        name: "index_review_comment_reactions_on_identity"
      table.check_constraint \
        "content IN ('+1', '-1', 'laugh', 'hooray', 'confused', 'heart', 'rocket', 'eyes')",
        name: "review_comment_reactions_content"
    end

    create_table :review_thread_reads do |table|
      table.references \
        :root,
        null: false,
        foreign_key: { to_table: :review_comments, on_delete: :cascade }
      table.references \
        :user,
        null: false,
        foreign_key: { on_delete: :restrict }
      table.integer :last_seen_activity_version, null: false
      table.datetime :read_at, null: false
      table.timestamps

      table.index \
        %i[root_id user_id],
        unique: true,
        name: "index_review_thread_reads_on_root_and_user"
      table.check_constraint \
        "last_seen_activity_version > 0",
        name: "review_thread_reads_positive_version"
    end

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          INSERT INTO review_thread_reads (
            root_id,
            user_id,
            last_seen_activity_version,
            read_at,
            created_at,
            updated_at
          )
          SELECT
            roots.id,
            participants.user_id,
            roots.activity_version,
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP
          FROM review_comments roots
          INNER JOIN (
            SELECT id AS root_id, user_id
            FROM review_comments
            WHERE root_id IS NULL
            UNION
            SELECT root_id, user_id
            FROM review_comments
            WHERE root_id IS NOT NULL
          ) participants ON participants.root_id = roots.id
          WHERE roots.root_id IS NULL
        SQL
      end
    end
  end
end
