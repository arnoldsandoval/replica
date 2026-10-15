class AddRenewableCanvasConnections < ActiveRecord::Migration[8.1]
  def change
    add_column :canvas_grants, :refresh_token_digest, :string
    add_column :canvas_grants, :last_active_at, :datetime
    add_column :canvas_grants, :inactive_at, :datetime
    add_index :canvas_grants, :refresh_token_digest, unique: true
    add_index :canvas_grants, :inactive_at
    add_check_constraint :canvas_grants,
      "(refresh_token_digest IS NULL AND last_active_at IS NULL AND inactive_at IS NULL) OR " \
      "(refresh_token_digest IS NOT NULL AND last_active_at IS NOT NULL AND inactive_at IS NOT NULL AND inactive_at > last_active_at)",
      name: "canvas_grants_renewable"
    add_column :canvas_pairings, :refresh_token_digest, :string
  end
end
