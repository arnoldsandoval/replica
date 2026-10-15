# Records the Hub administrator who connected Copilot and what Copilot last said about the token
# Hub uses. The token comes from REPLICA_COPILOT_TOKEN; the table keeps only its SHA-256 digest.
class CreateCopilotConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :copilot_connections do |t|
      t.integer :singleton_key, null: false, default: 1
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :token_digest, null: false
      t.datetime :verified_at, null: false
      t.datetime :refused_at
      t.timestamps
      t.index :singleton_key, unique: true
    end
    add_check_constraint :copilot_connections, "singleton_key = 1", name: "copilot_connections_singleton"
    add_check_constraint \
      :copilot_connections,
      "length(token_digest) = 64 AND token_digest NOT GLOB '*[^0-9a-f]*'",
      name: "copilot_connections_token_digest"
  end
end
