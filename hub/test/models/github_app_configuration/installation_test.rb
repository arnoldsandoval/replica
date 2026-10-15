require "test_helper"

class GithubAppConfiguration::InstallationTest < ActiveSupport::TestCase
  test "records an installation for the configured owner" do
    configuration = github_app_configurations.create
    payload = installation_payload
    client = Object.new
    installations = Object.new
    installations.define_singleton_method(:get) { |_id, token:| payload }
    installations.define_singleton_method(:repositories) { |token:| [] }
    client.define_singleton_method(:installations) { installations }
    configuration.define_singleton_method(:github_client) { client }
    configuration.tokens.define_singleton_method(:app) { "app-token" }
    configuration.tokens.define_singleton_method(:installation) { "installation-token" }

    configuration.installation.reconcile!(456)

    assert_equal 456, configuration.reload.installation_id
    assert_equal "active", configuration.installation_state
    assert_equal "github", configuration.owner_login
    assert configuration.installed_at
    assert configuration.installation_checked_at
  end

  test "rejects an installation owned by another account" do
    configuration = github_app_configurations.create
    payload = installation_payload
    payload["account"] = payload.fetch("account").merge("id" => 999)

    assert_raises(GithubAppConfiguration::Installation::OwnerMismatch) do
      configuration.installation.record_status!(payload)
    end

    assert_equal "not_installed", configuration.reload.installation_state
  end

  test "ignores removal of an older installation" do
    configuration = github_app_configurations.create_installed
    payload = installation_payload.merge("id" => 1234)

    configuration.installation.record_status!(payload, action: "deleted")

    assert_equal 456, configuration.reload.installation_id
    assert_equal "active", configuration.installation_state
  end

  test "removes repositories when the current installation is suspended" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    payload = installation_payload.merge("suspended_at" => Time.current.iso8601)

    configuration.installation.record_status!(payload)

    assert_equal "suspended", configuration.reload.installation_state
    assert_equal "removed", repository.reload.installation_state
  end

  test "unchanged active and suspended polls only refresh their checked time" do
    configuration = github_app_configurations.create_installed
    stub_github_installation_token
    stub_github_repositories([])
    version = configuration.lock_version

    configuration.installation.record_status!(installation_payload)

    assert_equal version, configuration.reload.lock_version
    assert configuration.installation_checked_at
    payload = installation_payload.merge("suspended_at" => Time.current.iso8601)
    configuration.installation.record_status!(payload)
    assert_equal version + 1, configuration.reload.lock_version
    suspended_at = configuration.suspended_at
    checked_at = configuration.installation_checked_at

    travel 1.minute do
      configuration.installation.record_status!(payload)

      assert_equal version + 1, configuration.reload.lock_version
      assert_equal suspended_at, configuration.suspended_at
      assert_operator configuration.installation_checked_at, :>, checked_at
    end
  end

  private

  def installation_payload
    {
      "id" => 456,
      "app_id" => 123,
      "account" => { "id" => 321, "login" => "github", "type" => "Organization" },
      "suspended_at" => nil
    }
  end
end
