class CreateShareLinks < ActiveRecord::Migration[8.1]
  LABEL_MAXIMUM_BYTES = 100

  def change
    create_table :share_links do |table|
      table.references :prototype, null: false, index: false
      table.references :build, null: false
      table.references :created_by, null: false
      table.string :public_id, limit: 36, null: false
      table.string :label, limit: LABEL_MAXIMUM_BYTES, null: false
      table.datetime :expires_at
      table.timestamps
    end

    add_index \
      :share_links,
      :public_id,
      unique: true
    add_index \
      :share_links,
      %i[prototype_id expires_at id],
      name: "index_share_links_on_prototype_and_expiration"
    add_foreign_key \
      :share_links,
      :prototypes,
      on_delete: :restrict
    add_foreign_key \
      :share_links,
      :builds,
      column: %i[build_id prototype_id],
      primary_key: %i[id prototype_id],
      on_delete: :restrict,
      name: "fk_share_links_build_prototype"
    add_foreign_key \
      :share_links,
      :users,
      column: :created_by_id,
      on_delete: :restrict
    add_check_constraint \
      :share_links,
      "length(public_id) = 36 AND " \
        "substr(public_id, 9, 1) = '-' AND substr(public_id, 14, 1) = '-' AND " \
        "substr(public_id, 19, 1) = '-' AND substr(public_id, 24, 1) = '-' AND " \
        "length(replace(public_id, '-', '')) = 32 AND " \
        "replace(public_id, '-', '') NOT GLOB '*[^0-9a-f]*'",
      name: "share_links_public_id"
    add_check_constraint \
      :share_links,
      "length(trim(label)) > 0 AND " \
        "length(CAST(label AS BLOB)) <= #{LABEL_MAXIMUM_BYTES}",
      name: "share_links_label"
    add_check_constraint \
      :share_links,
      "expires_at IS NULL OR expires_at > created_at",
      name: "share_links_expiration"
  end
end
