require "test_helper"
require "rake"
require "tempfile"
require "tmpdir"

class GithubAppTasksTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if !Rake::Task.task_defined?("replica:github:diagnose")
    @task = Rake::Task["replica:github:diagnose"]
    @task.reenable
  end

  test "reports when the bootstrap secret is ready" do
    original = ENV["REPLICA_BOOTSTRAP_SECRET"]
    ENV["REPLICA_BOOTSTRAP_SECRET"] = github_app_configurations.bootstrap_secret

    output = capture_io { @task.invoke }.first

    assert_includes output, "Configuration: not configured"
    assert_includes output, "Bootstrap: ready"
  ensure
    ENV["REPLICA_BOOTSTRAP_SECRET"] = original
  end

  test "reports only an empty bootstrap secret as missing" do
    original = ENV["REPLICA_BOOTSTRAP_SECRET"]
    ENV["REPLICA_BOOTSTRAP_SECRET"] = "manual"

    output = capture_io { @task.invoke }.first

    assert_includes output, "Bootstrap: ready"
  ensure
    ENV["REPLICA_BOOTSTRAP_SECRET"] = original
  end

  test "only same-App emergency recovery remains as a packaged App maintenance command" do
    %w[reset rotate_credentials rotate_webhook_secret finish_webhook_rotation].each do |name|
      assert_not Rake::Task.task_defined?("replica:github:#{name}")
    end
    assert Rake::Task.task_defined?("replica:github:recover_credentials")
    assert Rake::Task.task_defined?("replica:github:poll")
  end

  test "recovery records anonymous decisions without deleting App or operator data" do
    configuration = github_app_configurations.create
    operator = users.create(hub_admin: true)
    recovery = Rake::Task["replica:github:recover_credentials"]
    recovery.reenable
    names = %w[REPLICA_CONFIRM_APP_RECOVERY REPLICA_GITHUB_CLIENT_SECRET_FILE REPLICA_GITHUB_PRIVATE_KEY_FILE]
    original = names.to_h { |name| [ name, ENV[name] ] }
    ENV.delete("REPLICA_CONFIRM_APP_RECOVERY")
    capture_io { assert_raises(SystemExit) { recovery.invoke } }
    event = SecurityAuditEvent.where(action: "github_app.recover_credentials").last
    assert_equal "denied", event.outcome
    assert_equal "command", event.context.fetch("source")
    recovery.reenable
    stub_request(:get, "#{GITHUB_API_URL}/app")
      .to_return(status: 200, body: JSON.generate(github_app_configurations.manifest_credentials))
    Tempfile.create("client-secret") do |secret|
      Tempfile.create("private-key") do |key|
        secret.write("replacement\n")
        secret.flush
        key.write(github_app_configurations.test_private_key)
        key.flush
        ENV["REPLICA_CONFIRM_APP_RECOVERY"] = GithubAppConfiguration::Administration::RECOVERY_PHRASE
        ENV["REPLICA_GITHUB_CLIENT_SECRET_FILE"] = secret.path
        ENV["REPLICA_GITHUB_PRIVATE_KEY_FILE"] = key.path
        output = capture_io { recovery.invoke }.first
        assert_includes output, "credentials saved"
        assert_not_includes output, "replacement"
        assert_not_includes output, "PRIVATE KEY"
      end
    end
    event = SecurityAuditEvent.where(action: "github_app.recover_credentials").last
    assert_equal "succeeded", event.outcome
    assert_equal configuration.id, event.context.fetch("github_app_configuration_id")
    assert_nil event.ip_address
    assert_nil event.user_id
    assert GithubAppConfiguration.exists?(configuration.id)
    assert_equal "replacement", configuration.reload.client_secret
    assert operator.reload.hub_admin?
    assert_equal 2, SecurityAuditEvent.where(action: "github_app.recover_credentials").count
  ensure
    original&.each { |name, value| ENV[name] = value }
  end

  test "recovery rejects broadly readable or oversized secret files without disclosing them" do
    configuration = github_app_configurations.create
    Tempfile.create("invalid-secret") do |secret|
      secret.write("must-not-be-disclosed")
      secret.flush
      secret.chmod(0o644)
      assert_raises(GithubAppConfiguration::Administration::InvalidCredentials) do
        configuration.recovery.call! \
          confirmation: GithubAppConfiguration::Administration::RECOVERY_PHRASE,
          client_secret_path: secret.path, private_key_path: secret.path
      end
      secret.chmod(0o600)
      secret.write("x" * 4096)
      secret.flush
      assert_raises(GithubAppConfiguration::Administration::InvalidCredentials) do
        configuration.recovery.call! \
          confirmation: GithubAppConfiguration::Administration::RECOVERY_PHRASE,
          client_secret_path: secret.path, private_key_path: secret.path
      end
    end
    assert_equal "client-secret", configuration.reload.client_secret
    assert_not_requested :get, "#{GITHUB_API_URL}/app"
  end

  test "recovery rejects symlinks and directories without following them" do
    configuration = github_app_configurations.create
    Dir.mktmpdir do |directory|
      Tempfile.create("secret") do |secret|
        secret.write("must-not-be-disclosed")
        secret.flush
        link = File.join(directory, "linked-secret")
        File.symlink(secret.path, link)
        [ link, directory ].each do |path|
          error = assert_raises(GithubAppConfiguration::Administration::InvalidCredentials) do
            configuration.recovery.call! \
              confirmation: GithubAppConfiguration::Administration::RECOVERY_PHRASE,
              client_secret_path: path, private_key_path: secret.path
          end
          assert_not_includes error.message, path
          assert_not_includes error.message, "must-not-be-disclosed"
        end
      end
    end
    assert_not_requested :get, "#{GITHUB_API_URL}/app"
    assert_equal "client-secret", configuration.reload.client_secret
  end
end
