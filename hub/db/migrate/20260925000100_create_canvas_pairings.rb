class CreateCanvasPairings < ActiveRecord::Migration[8.1]
  def change
    create_table :canvas_pairings do |table|
      table.references :repository, null: false, foreign_key: { on_delete: :cascade }
      table.references :user, foreign_key: { on_delete: :cascade }
      table.string :device_code_digest, null: false
      table.string :user_code, null: false
      table.datetime :expires_at, null: false
      table.datetime :approved_at
      table.datetime :consumed_at
      table.timestamps
    end

    add_index :canvas_pairings, :device_code_digest, unique: true
    add_index :canvas_pairings, :user_code, unique: true
    add_check_constraint :canvas_pairings,
      "(approved_at IS NULL AND user_id IS NULL) OR (approved_at IS NOT NULL AND user_id IS NOT NULL)",
      name: "canvas_pairings_approval"
    add_check_constraint :canvas_pairings,
      "consumed_at IS NULL OR approved_at IS NOT NULL",
      name: "canvas_pairings_consumption"
  end
end
