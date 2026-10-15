require "test_helper"

class GithubAppConfiguration::RotatorTest < ActiveSupport::TestCase
  test "verifies the key's same App identity without pretending to verify OAuth" do
    configuration = github_app_configurations.create
    request = stub_request(:get, "#{GITHUB_API_URL}/app")
      .to_return(status: 200, body: JSON.generate(github_app_configurations.manifest_credentials))

    configuration.rotator.verify_credentials! \
      client_secret: "not-an-oauth-verified-secret",
      private_key: github_app_configurations.test_private_key

    assert_requested request
    assert_not_requested :post, "#{GITHUB_URL}/login/oauth/access_token"
    assert_equal "client-secret", configuration.reload.client_secret
  end

  test "rejects another App and malformed keys before credentials are saved" do
    configuration = github_app_configurations.create
    stub_request(:get, "#{GITHUB_API_URL}/app")
      .to_return(status: 200, body: JSON.generate(
        github_app_configurations.manifest_credentials.merge("id" => 999)
      ))
    assert_raises(GithubAppConfiguration::Rotator::IdentityMismatch) do
      configuration.rotator.verify_credentials! \
        client_secret: "replacement", private_key: github_app_configurations.test_private_key
    end
    assert_raises(GithubAppConfiguration::Administration::InvalidCredentials) do
      configuration.rotator.verify_credentials!(client_secret: "replacement", private_key: "secret-not-a-key")
    end
    assert_equal "client-secret", configuration.reload.client_secret
  end

  test "malformed App owner responses fail without exposing remote content" do
    configuration = github_app_configurations.create
    stub_request(:get, "#{GITHUB_API_URL}/app")
      .to_return(status: 200, body: JSON.generate(id: 123, owner: "private-provider-content"))
    error = assert_raises(GithubAppConfiguration::Rotator::IdentityMismatch) do
      configuration.rotator.verify_credentials! \
        client_secret: "replacement", private_key: github_app_configurations.test_private_key
    end
    assert_not_includes error.message, "private-provider-content"
    assert_equal "client-secret", configuration.reload.client_secret
  end

  test "only the exact integer App and owner identity can validate replacement credentials" do
    configuration = github_app_configurations.create
    original = github_app_configurations.manifest_credentials
    payloads = [
      original.merge("id" => original.fetch("id").to_f),
      original.merge("id" => original.fetch("id").to_s),
      original.merge("owner" => original.fetch("owner").merge("id" => 999)),
      original.merge("owner" => original.fetch("owner").merge("id" => original.fetch("owner").fetch("id").to_f)),
      original.merge("owner" => original.fetch("owner").merge("type" => "User"))
    ]
    payloads.each do |payload|
      stub_request(:get, "#{GITHUB_API_URL}/app").to_return(status: 200, body: JSON.generate(payload))
      assert_raises(GithubAppConfiguration::Rotator::IdentityMismatch) do
        configuration.rotator.verify_credentials! \
          client_secret: "replacement", private_key: github_app_configurations.test_private_key
      end
      assert_equal "client-secret", configuration.reload.client_secret
    end
  end
end
