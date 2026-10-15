class CreateCanvasGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :canvas_grants do |table|
      table.references :user, null: false, foreign_key: { on_delete: :cascade }
      table.references :repository, null: false, foreign_key: { on_delete: :cascade }
      table.string :token_digest, null: false
      table.datetime :expires_at, null: false
      table.datetime :revoked_at
      table.timestamps
    end

    add_index :canvas_grants, :token_digest, unique: true
    add_check_constraint :canvas_grants, "expires_at > created_at",
      name: "canvas_grants_expiry"
  end
end
