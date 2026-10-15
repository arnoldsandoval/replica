class CreatePreviewGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :preview_grants do |t|
      t.references :build, null: false, foreign_key: { on_delete: :cascade }
      t.references :session, null: false, foreign_key: { on_delete: :cascade }
      t.string :token_digest, null: false
      t.string :return_path, null: false, limit: 2048
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :preview_grants, :token_digest, unique: true
    add_check_constraint \
      :preview_grants,
      "length(token_digest) = 64 AND token_digest NOT GLOB '*[^0-9a-f]*'",
      name: "preview_grants_token_digest"
    add_check_constraint \
      :preview_grants,
      "length(CAST(return_path AS BLOB)) BETWEEN 1 AND 2048 AND substr(return_path, 1, 1) = '/'",
      name: "preview_grants_return_path"
  end
end
