class CreateBranchBannerDismissals < ActiveRecord::Migration[8.1]
  def change
    create_table :branch_banner_dismissals do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :prototype, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
      t.index [ :user_id, :prototype_id ], unique: true
    end
  end
end
