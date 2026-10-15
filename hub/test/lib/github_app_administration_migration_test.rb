require "test_helper"
require Rails.root.join("db/migrate/20261005234000_add_github_app_administration").to_s

class GithubAppAdministrationMigrationTest < ActiveSupport::TestCase
  # The upgrade runs against a separate database, never the application test schema.
  class UpgradeRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  test "an upgraded overlap stays pending and preserves both stored secrets" do
    UpgradeRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = UpgradeRecord.connection
    connection.create_table(:github_app_configurations) do |table|
      table.text :webhook_secret
      table.text :previous_webhook_secret
    end
    connection.execute <<~SQL
      INSERT INTO github_app_configurations (webhook_secret, previous_webhook_secret)
      VALUES ('stored-current', 'stored-previous'), ('stored-current', NULL)
    SQL
    migration = AddGithubAppAdministration.new
    migration.define_singleton_method(:connection) { connection }
    migration.suppress_messages { migration.up }

    rows = connection.select_all("SELECT * FROM github_app_configurations ORDER BY id").to_a
    assert_equal "pending", rows.first.fetch("webhook_rotation_state")
    assert_equal "stored-current", rows.first.fetch("webhook_secret")
    assert_equal "stored-previous", rows.first.fetch("previous_webhook_secret")
    assert_equal "idle", rows.last.fetch("webhook_rotation_state")
    assert_equal 1, rows.first.fetch("credential_revision")
    assert_equal 0, rows.first.fetch("lock_version")
    assert_raises(ActiveRecord::StatementInvalid) do
      connection.execute("UPDATE github_app_configurations SET webhook_rotation_state = 'confirmed' WHERE id = 2")
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      connection.execute("UPDATE github_app_configurations SET webhook_request_token = 'attempt' WHERE id = 1")
    end
    migration.suppress_messages { migration.down }
    assert_equal %w[id webhook_secret previous_webhook_secret],
      connection.columns(:github_app_configurations).map(&:name)
  ensure
    UpgradeRecord.connection_pool.disconnect!
  end
end
