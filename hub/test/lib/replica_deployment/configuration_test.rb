require "test_helper"
require Rails.root.join("lib/replica_deployment/configuration")

class ReplicaDeployment::ConfigurationTest < ActiveSupport::TestCase
  test "generates deployment origins and independent secrets" do
    configuration = ReplicaDeployment::Configuration.generate("Hub.Example.com")

    assert_equal "https://hub.example.com", configuration.fetch("REPLICA_HUB_ORIGIN")
    assert_equal \
      "https://b{build_id}.preview.hub.example.com",
      configuration.fetch("REPLICA_PREVIEW_ORIGIN_TEMPLATE")
    assert_equal \
      "https://s{build_id}.preview.hub.example.com",
      configuration.fetch("REPLICA_SHARE_PREVIEW_ORIGIN_TEMPLATE")
    assert_equal 64, configuration.fetch("REPLICA_DATABASE_ENCRYPTION_PRIMARY_KEY").length
    assert_equal 64, configuration.fetch("REPLICA_DATABASE_ENCRYPTION_DETERMINISTIC_KEY").length
    assert_equal 64, configuration.fetch("REPLICA_DATABASE_ENCRYPTION_KEY_DERIVATION_SALT").length
    assert_equal 128, configuration.fetch("SECRET_KEY_BASE").length
    secrets = configuration.values_at \
      "REPLICA_BOOTSTRAP_SECRET",
      "SECRET_KEY_BASE",
      "REPLICA_DATABASE_ENCRYPTION_PRIMARY_KEY",
      "REPLICA_DATABASE_ENCRYPTION_DETERMINISTIC_KEY",
      "REPLICA_DATABASE_ENCRYPTION_KEY_DERIVATION_SALT"

    assert_equal 5, secrets.uniq.length
  end

  test "rejects an origin instead of a hostname" do
    error = assert_raises ReplicaDeployment::Configuration::InvalidHost do
      ReplicaDeployment::Configuration.generate("https://hub.example.com")
    end

    assert_equal "host must be a DNS name such as hub.example.com", error.message
  end

  test "rejects a single-label hostname" do
    assert_raises ReplicaDeployment::Configuration::InvalidHost do
      ReplicaDeployment::Configuration.generate("localhost")
    end
  end

  test "rejects an IP address" do
    assert_raises ReplicaDeployment::Configuration::InvalidHost do
      ReplicaDeployment::Configuration.generate("192.0.2.1")
    end
  end

  test "accepts the longest hostname that leaves room for preview prefixes" do
    host = [ "a" * 63, "b" * 63, "c" * 63, "d" * 32 ].join(".")

    configuration = ReplicaDeployment::Configuration.generate(host)

    assert_equal "https://#{host}", configuration.fetch("REPLICA_HUB_ORIGIN")
  end

  test "rejects a hostname that leaves no room for preview prefixes" do
    host = [ "a" * 63, "b" * 63, "c" * 63, "d" * 33 ].join(".")

    assert_raises ReplicaDeployment::Configuration::InvalidHost do
      ReplicaDeployment::Configuration.generate(host)
    end
  end

  test "formats dotenv output" do
    settings = {
      "REPLICA_HUB_ORIGIN" => "https://hub.example.com",
      "SECRET_KEY_BASE" => "secret"
    }
    output = ReplicaDeployment::Formatter.format \
      settings,
      "dotenv"

    assert_equal \
      "REPLICA_HUB_ORIGIN=https://hub.example.com\nSECRET_KEY_BASE=secret\n",
      output
  end

  test "formats JSON output" do
    settings = { "REPLICA_HUB_ORIGIN" => "https://hub.example.com" }
    output = ReplicaDeployment::Formatter.format \
      settings,
      "json"

    assert_equal({ "REPLICA_HUB_ORIGIN" => "https://hub.example.com" }, JSON.parse(output))
  end

  test "rejects an unknown output format" do
    error = assert_raises ReplicaDeployment::Formatter::InvalidFormat do
      ReplicaDeployment::Formatter.format({}, "yaml")
    end

    assert_equal "format must be dotenv or json", error.message
  end
end
