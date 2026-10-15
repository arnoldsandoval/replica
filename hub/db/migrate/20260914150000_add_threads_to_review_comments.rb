class AddThreadsToReviewComments < ActiveRecord::Migration[8.1]
  BODY_MAXIMUM_BYTES = 10_000
  ANCHOR_MAXIMUM_BYTES = 16_384

  OLD_BODY_CONSTRAINT =
    "length(trim(body)) > 0 AND length(CAST(body AS BLOB)) <= #{BODY_MAXIMUM_BYTES}"
  OLD_ANCHOR_SIZE_CONSTRAINT =
    "length(CAST(anchor AS BLOB)) BETWEEN 2 AND #{ANCHOR_MAXIMUM_BYTES}"
  OLD_ANCHOR_JSON_CONSTRAINT = "json_valid(anchor)"
  OLD_ANCHOR_OBJECT_CONSTRAINT = "json_type(anchor) = 'object'"

  def change
    remove_check_constraint \
      :review_comments,
      OLD_BODY_CONSTRAINT,
      name: "review_comments_body"
    remove_check_constraint \
      :review_comments,
      OLD_ANCHOR_SIZE_CONSTRAINT,
      name: "review_comments_anchor_size"
    remove_check_constraint \
      :review_comments,
      OLD_ANCHOR_JSON_CONSTRAINT,
      name: "review_comments_anchor_json"
    remove_check_constraint \
      :review_comments,
      OLD_ANCHOR_OBJECT_CONSTRAINT,
      name: "review_comments_anchor_object"

    change_column_null :review_comments, :build_id, true
    change_column_null :review_comments, :body, true
    change_column_null :review_comments, :anchor, true

    add_column :review_comments, :root_id, :integer
    add_column :review_comments, :edited_at, :datetime
    add_column :review_comments, :deleted_at, :datetime
    add_column :review_comments, :resolved_at, :datetime
    add_column :review_comments, :resolved_by_id, :integer

    add_index :review_comments, :root_id
    add_index :review_comments, :resolved_by_id
    add_index \
      :review_comments,
      %i[id prototype_id],
      unique: true,
      name: "index_review_comments_on_id_and_prototype"
    add_foreign_key \
      :review_comments,
      :review_comments,
      column: %i[root_id prototype_id],
      primary_key: %i[id prototype_id],
      on_delete: :restrict,
      name: "fk_review_comments_root_prototype"
    add_foreign_key \
      :review_comments,
      :users,
      column: :resolved_by_id,
      on_delete: :restrict

    add_check_constraint \
      :review_comments,
      "CASE WHEN deleted_at IS NULL THEN " \
        "body IS NOT NULL AND length(trim(body)) > 0 AND " \
        "length(CAST(body AS BLOB)) <= #{BODY_MAXIMUM_BYTES} " \
        "ELSE body IS NULL END",
      name: "review_comments_body"
    add_check_constraint \
      :review_comments,
      "(root_id IS NULL AND build_id IS NOT NULL AND anchor IS NOT NULL) OR " \
        "(root_id IS NOT NULL AND build_id IS NULL AND anchor IS NULL)",
      name: "review_comments_thread_shape"
    add_check_constraint \
      :review_comments,
      "anchor IS NULL OR " \
        "length(CAST(anchor AS BLOB)) BETWEEN 2 AND #{ANCHOR_MAXIMUM_BYTES}",
      name: "review_comments_anchor_size"
    add_check_constraint \
      :review_comments,
      "anchor IS NULL OR json_valid(anchor)",
      name: "review_comments_anchor_json"
    add_check_constraint \
      :review_comments,
      "anchor IS NULL OR json_type(anchor) = 'object'",
      name: "review_comments_anchor_object"
    add_check_constraint \
      :review_comments,
      "(resolved_at IS NULL AND resolved_by_id IS NULL) OR " \
        "(root_id IS NULL AND resolved_at IS NOT NULL AND resolved_by_id IS NOT NULL)",
      name: "review_comments_resolution"
    add_check_constraint \
      :review_comments,
      "root_id IS NULL OR root_id <> id",
      name: "review_comments_root_not_self"
    add_check_constraint \
      :review_comments,
      "edited_at IS NULL OR (deleted_at IS NULL AND edited_at >= created_at)",
      name: "review_comments_edit_state"
    add_check_constraint \
      :review_comments,
      "deleted_at IS NULL OR deleted_at >= created_at",
      name: "review_comments_deletion_time"
  end
end
