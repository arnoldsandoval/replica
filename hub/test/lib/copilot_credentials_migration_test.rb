require "test_helper"
require Rails.root.join("db/migrate/20261010000100_create_copilot_connections").to_s
require Rails.root.join("db/migrate/20261015000100_remove_legacy_copilot_credentials").to_s

class CopilotCredentialsMigrationTest < ActiveSupport::TestCase
  class UpgradeRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  test "an earlier pre-release schema loses only its Copilot credentials and enablement" do
    with_database do |connection|
      connection.create_table(:copilot_connections) do |table|
        table.integer :singleton_key, null: false, default: 1
        table.references :github_app_configuration, null: false, foreign_key: { on_delete: :cascade }
        table.references :user, null: false, foreign_key: { on_delete: :cascade }
        table.text :access_token, null: false
        table.datetime :access_token_expires_at
        table.text :refresh_token
        table.datetime :refresh_token_expires_at
        table.datetime :verified_at, null: false
        table.datetime :refused_at
        table.timestamps
        table.index :singleton_key, unique: true
      end
      connection.add_check_constraint \
        :copilot_connections, "singleton_key = 1", name: "copilot_connections_singleton"
      now = connection.quote(Time.current)
      connection.execute <<~SQL
        INSERT INTO copilot_connections
          (github_app_configuration_id, user_id, access_token, refresh_token, verified_at, created_at, updated_at)
        VALUES (1, 1, 'synthetic-access-ciphertext', 'synthetic-refresh-ciphertext', #{now}, #{now}, #{now})
      SQL

      migrate(connection, RemoveLegacyCopilotCredentials.new)

      assert_equal %w[id singleton_key user_id verified_at refused_at created_at updated_at token_digest],
        connection.columns(:copilot_connections).map(&:name)
      assert_equal 0, connection.select_value("SELECT COUNT(*) FROM copilot_connections")
      assert_equal [ "users" ], connection.foreign_keys(:copilot_connections).map(&:to_table)
      assert_equal [ "copilot_connections_singleton", "copilot_connections_token_digest" ],
        connection.check_constraints(:copilot_connections).map(&:name).sort
      assert_equal [ "retained-user" ], connection.select_values("SELECT login FROM users")
      assert_equal [ "retained-app" ], connection.select_values("SELECT name FROM github_app_configurations")
      assert_equal [ "retained-build" ], connection.select_values("SELECT name FROM builds")
      assert_equal [ "copilot_connection.connect" ], connection.select_values("SELECT action FROM security_audit_events")

      insert_connection(connection)
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute("UPDATE copilot_connections SET token_digest = 'invalid'")
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute("UPDATE copilot_connections SET singleton_key = 2")
      end
      connection.execute("DELETE FROM github_app_configurations")
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM copilot_connections")
      connection.execute("DELETE FROM users")
      assert_equal 0, connection.select_value("SELECT COUNT(*) FROM copilot_connections")
    end
  end

  test "a fresh digest-only schema and existing operator enablement stay unchanged" do
    with_database do |connection|
      migrate(connection, CreateCopilotConnections.new)
      insert_connection(connection)
      before = connection.select_all("SELECT * FROM copilot_connections").to_a
      columns = connection.columns(:copilot_connections).map(&:name)

      migrate(connection, RemoveLegacyCopilotCredentials.new)
      migrate(connection, RemoveLegacyCopilotCredentials.new)

      assert_equal columns, connection.columns(:copilot_connections).map(&:name)
      assert_equal before, connection.select_all("SELECT * FROM copilot_connections").to_a
    end
  end

  test "rollback never pretends to restore discarded credentials or verification" do
    with_database do |connection|
      error = assert_raises(ActiveRecord::IrreversibleMigration) do
        RemoveLegacyCopilotCredentials.new.exec_migration(connection, :down)
      end

      assert_match "cannot be restored", error.message
    end
  end

  private

  # Each migration runs against synthetic records in its own database, never Hub's test schema.
  def with_database
    UpgradeRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = UpgradeRecord.connection
    connection.create_table(:users) { |table| table.string :login }
    connection.create_table(:github_app_configurations) { |table| table.string :name }
    connection.create_table(:builds) { |table| table.string :name }
    connection.create_table(:security_audit_events) { |table| table.string :action }
    connection.execute("INSERT INTO users (id, login) VALUES (1, 'retained-user')")
    connection.execute("INSERT INTO github_app_configurations (id, name) VALUES (1, 'retained-app')")
    connection.execute("INSERT INTO builds (name) VALUES ('retained-build')")
    connection.execute("INSERT INTO security_audit_events (action) VALUES ('copilot_connection.connect')")
    yield connection
  ensure
    UpgradeRecord.connection_pool.disconnect!
  end

  # Uses the migration's normal adapter API without switching application connections.
  def migrate(connection, migration)
    migration.suppress_messages { migration.exec_migration(connection, :up) }
  end

  # Represents a new explicit operator-token check, not carried-over OAuth verification.
  def insert_connection(connection)
    now = connection.quote(Time.current)
    connection.execute <<~SQL
      INSERT INTO copilot_connections (user_id, token_digest, verified_at, created_at, updated_at)
      VALUES (1, '#{"a" * 64}', #{now}, #{now}, #{now})
    SQL
  end
end
