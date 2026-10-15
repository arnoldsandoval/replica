class CreateSharePreviewGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :share_preview_grants do |table|
      table.references \
        :share_link,
        null: false,
        foreign_key: { on_delete: :cascade }
      table.string :token_digest, null: false
      table.datetime :expires_at, null: false
      table.timestamps
    end

    add_index \
      :share_preview_grants,
      :token_digest,
      unique: true
    add_check_constraint \
      :share_preview_grants,
      "length(token_digest) = 64 AND token_digest NOT GLOB '*[^0-9a-f]*'",
      name: "share_preview_grants_token_digest"
  end
end
