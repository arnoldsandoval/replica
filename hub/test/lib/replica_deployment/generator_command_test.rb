require "test_helper"
require "json"
require "open3"

class ReplicaDeployment::GeneratorCommandTest < ActiveSupport::TestCase
  test "prints JSON configuration without booting Rails" do
    stdout, stderr, status = Open3.capture3 \
      Rails.root.join("bin/replica-deployment-config").to_s,
      "generate",
      "--host",
      "hub.example.com",
      "--format",
      "json"

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "https://hub.example.com", JSON.parse(stdout).fetch("REPLICA_HUB_ORIGIN")
  end

  test "reports an invalid hostname without printing configuration" do
    stdout, stderr, status = Open3.capture3 \
      Rails.root.join("bin/replica-deployment-config").to_s,
      "generate",
      "--host",
      "https://hub.example.com"

    assert_not status.success?
    assert_empty stdout
    assert_includes stderr, "host must be a DNS name such as hub.example.com"
  end
end
