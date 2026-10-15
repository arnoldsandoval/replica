require "test_helper"

class GithubAppConfiguration::TokensTest < ActiveSupport::TestCase
  test "creates a short-lived RS256 App token" do
    configuration = github_app_configurations.create
    token = configuration.tokens.app
    public_key = OpenSSL::PKey::RSA.new(github_app_configurations.test_private_key).public_key
    payload, headers = JWT.decode(token, public_key, true, algorithm: "RS256")

    assert_equal "RS256", headers.fetch("alg")
    assert_equal "Iv1.test", payload.fetch("iss")
    assert_operator payload.fetch("exp") - payload.fetch("iat"), :<=, 10.minutes.to_i
  end

  test "requests and reuses an installation token" do
    configuration = github_app_configurations.create_installed
    client = Object.new
    requests = 0
    installations = Object.new
    installations.define_singleton_method(:create_token) do |id, token:|
      requests += 1
      raise "wrong installation" if id != 456

      { "token" => "installation-token", "expires_at" => 1.hour.from_now.iso8601 }
    end
    client.define_singleton_method(:installations) { installations }
    configuration.define_singleton_method(:github_client) { client }

    assert_equal "installation-token", configuration.tokens.installation
    assert_equal "installation-token", configuration.tokens.installation
    assert_equal 1, requests
  end

  test "does not reuse a token after installation status changes" do
    configuration = github_app_configurations.create_installed
    client = Object.new
    installations = Object.new
    installations.define_singleton_method(:create_token) do |*_args, **_options|
      { "token" => "installation-token", "expires_at" => 1.hour.from_now.iso8601 }
    end
    client.define_singleton_method(:installations) { installations }
    configuration.define_singleton_method(:github_client) { client }
    configuration.tokens.installation
    configuration.update!(installation_state: "suspended", suspended_at: Time.current)

    assert_raises(GithubClient::InvalidResponse) { configuration.tokens.installation }
  end

  test "rejects blank and expired installation tokens" do
    [
      { "token" => "", "expires_at" => 1.hour.from_now.iso8601 },
      { "token" => "installation-token", "expires_at" => 1.minute.ago.iso8601 }
    ].each do |payload|
      GithubAppConfiguration.delete_all
      configuration = github_app_configurations.create_installed
      installations = Object.new
      installations.define_singleton_method(:create_token) { |*_args, **_options| payload }
      client = Object.new
      client.define_singleton_method(:installations) { installations }
      configuration.define_singleton_method(:github_client) { client }

      assert_raises(GithubClient::InvalidResponse) { configuration.tokens.installation }
    end
  end
end
