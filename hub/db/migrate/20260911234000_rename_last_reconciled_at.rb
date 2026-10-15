class RenameLastReconciledAt < ActiveRecord::Migration[8.1]
  def change
    rename_column \
      :github_app_configurations,
      :last_reconciled_at,
      :installation_checked_at
  end
end
