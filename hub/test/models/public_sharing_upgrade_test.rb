require "test_helper"
require Rails.root.join("db/migrate/20261006000000_add_public_sharing_controls")

class PublicSharingUpgradeTest < ActiveSupport::TestCase
  class UpgradeDatabase < ActiveRecord::Base
    self.abstract_class = true
  end

  test "upgrading disables sharing and permanently revokes pre existing links and handoffs" do
    UpgradeDatabase.establish_connection(adapter: "sqlite3", database: ":memory:")
    UpgradeDatabase.connection_pool.with_connection do |connection|
      connection.create_table(:repositories)
      connection.create_table(:users)
      connection.create_table(:share_links) { |table| table.string :public_id }
      connection.create_table(:share_preview_grants) { |table| table.integer :share_link_id }
      connection.execute("INSERT INTO share_links (id, public_id) VALUES (1, 'existing-link')")
      connection.execute("INSERT INTO share_preview_grants (share_link_id) VALUES (1)")
      AddPublicSharingControls.new.exec_migration(connection, :up)

      assert_equal 0, connection.select_value("SELECT COUNT(*) FROM sharing_settings")
      assert connection.select_value("SELECT revoked_at FROM share_links WHERE id = 1")
      assert_equal 0, connection.select_value("SELECT COUNT(*) FROM share_preview_grants")
      connection.execute("INSERT INTO sharing_settings (id, created_at, updated_at) VALUES (1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
      assert_equal 0, connection.select_value("SELECT public_sharing_enabled FROM sharing_settings")
      connection.execute("UPDATE sharing_settings SET public_sharing_enabled = 1")
      assert connection.select_value("SELECT revoked_at FROM share_links WHERE id = 1")
      assert_raises(ActiveRecord::IrreversibleMigration) { AddPublicSharingControls.new.down }
    end
  ensure
    UpgradeDatabase.remove_connection
  end
end
