require "test_helper"

class GithubAppConfigurationTest < ActiveSupport::TestCase
  test "encrypts credentials at rest" do
    credentials = github_app_configurations.attributes_for
    configuration = GithubAppConfiguration.install!(credentials)
    stored = GithubAppConfiguration.connection.select_one \
      "SELECT client_secret, private_key, webhook_secret FROM github_app_configurations WHERE id = #{configuration.id}"

    configuration.reload
    %i[client_secret private_key webhook_secret].each do |attribute|
      plaintext = credentials.fetch(attribute)
      ciphertext = stored.fetch(attribute.to_s)
      encrypted = JSON.parse(ciphertext)

      assert_not_includes ciphertext, plaintext
      assert_predicate encrypted.fetch("p"), :present?
      assert_predicate encrypted.fetch("h").fetch("iv"), :present?
      assert_predicate encrypted.fetch("h").fetch("at"), :present?
      assert_equal plaintext, configuration.public_send(attribute)
    end
  end

  test "enforces one row in the database" do
    github_app_configurations.create

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      GithubAppConfiguration.insert_all! \
        [ github_app_configurations.attributes_for.merge(singleton_key: 1) ]
    end

    assert_match(/singleton_key/, error.message)
  end

  test "requires installation identity to match state" do
    configuration = github_app_configurations.new
    configuration.installation_state = "active"

    assert_not configuration.valid?
    assert_includes configuration.errors[:installation_id], "does not match installation state"
  end
end
