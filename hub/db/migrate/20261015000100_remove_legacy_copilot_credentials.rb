# Earlier pre-release checkouts stored GitHub App user tokens. End that enablement rather than
# treating it as proof that the new operator-provided token works. Audit history stays unchanged.
class RemoveLegacyCopilotCredentials < ActiveRecord::Migration[8.1]
  def up
    return if !column_exists?(:copilot_connections, :access_token)

    execute "DELETE FROM copilot_connections"
    remove_reference :copilot_connections, :github_app_configuration, foreign_key: true
    remove_column :copilot_connections, :access_token
    remove_column :copilot_connections, :access_token_expires_at
    remove_column :copilot_connections, :refresh_token
    remove_column :copilot_connections, :refresh_token_expires_at
    add_column :copilot_connections, :token_digest, :string, null: false
    add_check_constraint \
      :copilot_connections,
      "length(token_digest) = 64 AND token_digest NOT GLOB '*[^0-9a-f]*'",
      name: "copilot_connections_token_digest"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Removed Copilot credentials and verification cannot be restored."
  end
end
