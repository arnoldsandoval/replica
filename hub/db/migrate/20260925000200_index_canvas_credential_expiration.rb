class IndexCanvasCredentialExpiration < ActiveRecord::Migration[8.1]
  def change
    add_index :canvas_pairings, :expires_at
    add_index :canvas_pairings, :consumed_at, where: "consumed_at IS NOT NULL"
    add_index :canvas_grants, :expires_at
    add_index :canvas_grants, :revoked_at, where: "revoked_at IS NOT NULL"
  end
end
