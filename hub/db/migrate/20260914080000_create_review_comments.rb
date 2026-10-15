class CreateReviewComments < ActiveRecord::Migration[8.1]
  BODY_MAXIMUM_BYTES = 10_000
  ANCHOR_MAXIMUM_BYTES = 16_384

  def change
    add_index :builds, %i[id prototype_id], unique: true

    create_table :review_comments do |table|
      table.references :prototype, null: false, index: false
      table.references :build, null: false
      table.references :user, null: false
      table.text :body, null: false
      table.json :anchor, null: false
      table.timestamps
    end

    add_index \
      :review_comments,
      %i[prototype_id created_at id],
      order: { created_at: :desc, id: :desc },
      name: "index_review_comments_on_prototype_and_created_at"
    add_foreign_key \
      :review_comments,
      :prototypes,
      on_delete: :restrict
    add_foreign_key \
      :review_comments,
      :builds,
      column: %i[build_id prototype_id],
      primary_key: %i[id prototype_id],
      on_delete: :restrict,
      name: "fk_review_comments_build_prototype"
    add_foreign_key \
      :review_comments,
      :users,
      on_delete: :restrict
    add_check_constraint \
      :review_comments,
      "length(trim(body)) > 0 AND " \
        "length(CAST(body AS BLOB)) <= #{BODY_MAXIMUM_BYTES}",
      name: "review_comments_body"
    add_check_constraint \
      :review_comments,
      "length(CAST(anchor AS BLOB)) BETWEEN 2 AND #{ANCHOR_MAXIMUM_BYTES}",
      name: "review_comments_anchor_size"
    add_check_constraint \
      :review_comments,
      "json_valid(anchor)",
      name: "review_comments_anchor_json"
    add_check_constraint \
      :review_comments,
      "json_type(anchor) = 'object'",
      name: "review_comments_anchor_object"
  end
end
