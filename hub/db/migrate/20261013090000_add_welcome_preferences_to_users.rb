class AddWelcomePreferencesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :welcome_hidden, :boolean, default: false, null: false
    add_column :users, :welcome_sign_in_pending, :boolean, default: false, null: false
    change_column_default :users, :welcome_sign_in_pending, from: false, to: true
  end
end
