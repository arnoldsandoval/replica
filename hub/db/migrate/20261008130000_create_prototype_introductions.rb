class CreatePrototypeIntroductions < ActiveRecord::Migration[8.1]
  def change
    create_table :prototype_introductions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :prototype, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
      t.index [ :user_id, :prototype_id ], unique: true
    end
  end
end
