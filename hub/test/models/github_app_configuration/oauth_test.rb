require "test_helper"

class GithubAppConfiguration::OauthTest < ActiveSupport::TestCase
  test "creates one-use OAuth state and PKCE challenge" do
    configuration = installed_configuration
    browser_session = {}

    url = configuration.oauth.authorize_url(browser_session)

    query = Rack::Utils.parse_query(URI(url).query)
    assert_equal configuration.client_id, query.fetch("client_id")
    assert_equal browser_session.fetch(:github_oauth_state), query.fetch("state")
    assert_equal "S256", query.fetch("code_challenge_method")
    assert browser_session.fetch(:github_oauth_verifier).present?
    assert_equal SessionRevocation.current.generation, browser_session.fetch(:github_oauth_generation)
    assert_equal configuration.id, browser_session.fetch(:github_oauth_configuration_id)
    assert_equal configuration.credential_revision, browser_session.fetch(:github_oauth_credential_revision)
  end

  test "authenticates an admitted GitHub identity without storing the OAuth token" do
    configuration = installed_configuration
    browser_session = {}
    url = configuration.oauth.authorize_url(browser_session)
    state = Rack::Utils.parse_query(URI(url).query).fetch("state")
    repository = repositories.create
    client = Object.new
    oauth = Object.new
    oauth.define_singleton_method(:exchange_code) { |**_options| "temporary-token" }
    oauth.define_singleton_method(:user) do |token:|
      { "id" => 1001, "login" => "octocat", "name" => "Octocat", "avatar_url" => nil }
    end
    client.define_singleton_method(:oauth) { oauth }
    installations = Object.new
    installations.define_singleton_method(:repositories) do |token:|
      [ { "id" => repository.github_id, "full_name" => repository.name_with_owner,
        "default_branch" => repository.default_branch } ]
    end
    client.define_singleton_method(:installations) { installations }
    github_repositories = Object.new
    github_repositories.define_singleton_method(:permission) do |_repository, _user, token:|
      { "permission" => "pull", "user" => { "id" => 1001 } }
    end
    client.define_singleton_method(:repositories) { github_repositories }
    configuration.define_singleton_method(:github_client) { client }

    user = configuration.oauth.authenticate!(browser_session, code: "code", state:)

    assert_equal 1001, user.github_id
    assert_not User.column_names.include?("access_token")
    assert_nil browser_session[:github_oauth_state]
  end

  test "rejects reused OAuth state before exchange" do
    configuration = installed_configuration
    browser_session = {}
    state = Rack::Utils.parse_query(URI(configuration.oauth.authorize_url(browser_session)).query).fetch("state")
    browser_session.delete(:github_oauth_verifier)

    assert_raises(GithubAppConfiguration::Oauth::InvalidState) do
      configuration.oauth.authenticate!(browser_session, code: "code", state:)
    end
  end

  test "missing malformed and superseded generations deny before GitHub exchange" do
    configuration = installed_configuration
    generation = SessionRevocation.current.generation
    [ nil, generation.to_s, -1, generation + 1 ].each do |snapshot|
      browser = {}
      configuration.oauth.authorize_url(browser)
      state = browser.fetch(:github_oauth_state)
      browser[:github_oauth_generation] = snapshot
      assert_raises(SessionRevocation::Superseded) do
        configuration.oauth.authenticate!(browser, code: "code", state:)
      end
      assert_empty browser
    end
    assert_empty User.all
  end

  test "fresh identity verification uses the registered callback without repository admission or token storage" do
    configuration = installed_configuration
    browser_session = {}
    url = configuration.oauth.authorize_url(browser_session)
    query = Rack::Utils.parse_query(URI(url).query)
    assert_equal "#{Rails.configuration.x.hub_origin}/auth/github/callback", query.fetch("redirect_uri")
    stub_github_oauth_user(github_id: 1002, login: "operator")
    profile = configuration.oauth.verified_profile!(browser_session, code: "code", state: query.fetch("state"))
    assert_equal 1002, profile.fetch("id")
    assert_empty User.all
    assert_empty browser_session
    assert_raises(GithubAppConfiguration::Oauth::InvalidState) do
      configuration.oauth.verified_profile!(browser_session, code: "code", state: query.fetch("state"))
    end
  end

  test "missing malformed and stale App snapshots deny before exchange and clear the whole flow" do
    configuration = installed_configuration
    [ :github_oauth_configuration_id, :github_oauth_credential_revision ].each do |key|
      [ nil, "1", 0, -1, 1.0, configuration.id + 100 ].each do |value|
        browser = {}
        configuration.oauth.authorize_url(browser)
        state = browser.fetch(:github_oauth_state)
        browser[key] = value
        assert_raises(GithubAppConfiguration::Oauth::InvalidState,
          GithubAppConfiguration::Superseded) do
          configuration.oauth.authenticate!(browser, code: "code", state:)
        end
        assert_empty browser
      end
    end
    assert_empty User.all
    assert_not_requested :post, "#{GITHUB_URL}/login/oauth/access_token"
  end

  test "changed credentials reject old OAuth state before exchange" do
    configuration = installed_configuration
    browser_session = {}
    state = Rack::Utils.parse_query(URI(configuration.oauth.authorize_url(browser_session)).query).fetch("state")
    configuration.update!(credential_revision: 2)
    assert_raises(GithubAppConfiguration::Oauth::InvalidState) do
      configuration.oauth.verified_profile!(browser_session, code: "code", state:)
    end
    assert_empty browser_session
    assert_not_requested :post, "#{GITHUB_URL}/login/oauth/access_token"
  end

  test "a generation change during identity verification prevents administrator admission" do
    configuration = installed_configuration
    actor = users.create(hub_admin: true)
    browser_session = {}
    state = Rack::Utils.parse_query(URI(configuration.oauth.authorize_url(browser_session)).query).fetch("state")
    stub_github_oauth_user
    stub_request(:get, "#{GITHUB_API_URL}/user").to_return do
      GithubAppConfiguration.find(configuration.id).update!(credential_revision: 2)
      { status: 200, body: JSON.generate(id: actor.github_id, login: actor.login) }
    end
    assert_raises(GithubAppConfiguration::Superseded) do
      configuration.oauth.authenticate!(browser_session, code: "code", state:)
    end
    assert_empty browser_session
  end

  private

  def installed_configuration
    configuration = github_app_configurations.create_installed
    configuration.tokens.define_singleton_method(:installation) { "installation-token" }
    configuration
  end
end
