require "test_helper"
require Rails.root.join("db/migrate/20261013090000_add_welcome_preferences_to_users").to_s

class WelcomePreferencesMigrationTest < ActiveSupport::TestCase
  class UpgradeRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  test "existing accounts keep their landing page while new accounts start with welcome" do
    UpgradeRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = UpgradeRecord.connection
    connection.create_table(:users) { |table| table.string :login, null: false }
    connection.add_index(:users, :login, unique: true)
    connection.execute("INSERT INTO users (login) VALUES ('existing')")
    migration = AddWelcomePreferencesToUsers.new
    migration.suppress_messages { migration.exec_migration(connection, :up) }
    connection.execute("INSERT INTO users (login) VALUES ('new')")

    rows = connection.select_all("SELECT * FROM users ORDER BY id").to_a
    assert_equal 0, rows.first.fetch("welcome_sign_in_pending")
    assert_equal 1, rows.last.fetch("welcome_sign_in_pending")
    assert_equal [ 0, 0 ], rows.map { _1.fetch("welcome_hidden") }
    assert_raises(ActiveRecord::StatementInvalid) do
      connection.execute("UPDATE users SET welcome_hidden = NULL")
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      connection.execute("INSERT INTO users (login) VALUES ('existing')")
    end

    migration.suppress_messages { migration.exec_migration(connection, :down) }
    assert_equal %w[id login], connection.columns(:users).map(&:name)
    assert_equal 2, connection.select_value("SELECT COUNT(*) FROM users")
  ensure
    UpgradeRecord.connection_pool.disconnect!
  end
end
