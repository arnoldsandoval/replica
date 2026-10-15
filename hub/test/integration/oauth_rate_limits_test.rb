require "test_helper"
require_relative "../support/security_rate_limit_store"

class OauthRateLimitsTest < ActionDispatch::IntegrationTest
  include SecurityRateLimitStore

  setup do
    github_app_configurations.create_installed
    use_security_rate_limit_store
    travel_to Time.current.change(usec: 0)
  end

  teardown do
    restore_security_rate_limit_store
    travel_back
  end

  test "initiation and callback each admit exactly sixty requests and reset at five minutes" do
    started = Time.current
    60.times do
      post github_authentication_path, as: :json
      assert_response :found
      get github_authentication_callback_path, params: { state: "invalid", code: "unused" }, as: :json
      assert_response :redirect
    end
    post github_authentication_path, as: :json
    assert_security_throttle(300)
    get github_authentication_callback_path, params: { state: "invalid", code: "unused" }, as: :json
    assert_security_throttle(300)
    assert_not_requested :post, "https://github.com/login/oauth/access_token"

    travel_to started + 5.minutes
    post github_authentication_path, as: :json
    assert_response :found
    get github_authentication_callback_path, params: { state: "invalid", code: "unused" }, as: :json
    assert_response :redirect
  end

  test "untrusted forwarded addresses cannot split a socket peer's budget" do
    60.times do |index|
      post github_authentication_path, headers: {
        "REMOTE_ADDR" => "203.0.113.10", "X-Forwarded-For" => "198.51.100.#{index + 1}"
      }, as: :json
      assert_response :found
    end
    post github_authentication_path, headers: {
      "REMOTE_ADDR" => "203.0.113.10", "X-Forwarded-For" => "198.51.100.200"
    }, as: :json
    assert_security_throttle(300)
    post github_authentication_path, headers: { "REMOTE_ADDR" => "203.0.113.11" }, as: :json
    assert_response :found
  end

  test "fresh verification shares initiation rather than getting another controller budget" do
    user = users.create(hub_admin: true)
    credential = user.sessions.create!
    challenge = FreshAuthorization.start!(credential:, purpose: "hub_admin_management", return_to: "/hub_admins")
    60.times { post github_authentication_path, as: :json }

    assert_no_difference("SecurityAuditEvent.count") do
      post fresh_authorization_path(challenge.public_id), as: :json
      assert_security_throttle(300)
    end
    assert_nil challenge.reload.oauth_state_digest
  end

  test "unknown and deleted fresh starts spend the existing budget without replacing an active flow" do
    user = users.create(hub_admin: true)
    stub_github_oauth_user
    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
    credential = user.sessions.sole
    challenge = FreshAuthorization.start!(credential:, purpose: "hub_admin_management", return_to: "/hub_admins")
    deleted = FreshAuthorization.start!(credential:, purpose: "hub_admin_management", return_to: "/hub_admins")
    deleted.destroy!
    Rails.cache.clear

    post fresh_authorization_path(challenge.public_id), as: :json
    assert_response :see_other
    bundle = oauth_bundle
    assert_equal challenge.id, bundle.fetch("fresh_authorization_id")
    assert_equal SessionRevocation.current.generation, bundle.fetch("github_oauth_generation")
    assert_equal GithubAppConfiguration.current.id, bundle.fetch("github_oauth_configuration_id")
    assert_equal GithubAppConfiguration.current.credential_revision, bundle.fetch("github_oauth_credential_revision")
    assert_difference("SecurityAuditEvent.count", 59) do
      59.times do |index|
        id = index.even? ? SecureRandom.uuid : deleted.public_id
        post fresh_authorization_path(id), as: :json
        assert_redirected_to root_path
        assert_equal bundle, oauth_bundle
      end
    end
    assert_equal 60, Rails.cache.read("rate-limit:security:oauth_initiation:#{request.remote_ip}")
    before = challenge.reload.attributes

    original_lookup = FreshAuthorization.method(:find_by!)
    FreshAuthorization.define_singleton_method(:find_by!) do |*|
      raise Minitest::Assertion, "A throttled request must not look up a challenge"
    end
    assert_no_difference([ "SecurityAuditEvent.count", "FreshAuthorization.count", "Session.count" ]) do
      [ SecureRandom.uuid, deleted.public_id, challenge.public_id ].each do |id|
        post fresh_authorization_path(id), as: :json
        assert_security_throttle(300)
        assert_equal bundle, oauth_bundle
      end
    end
    assert_equal before, challenge.reload.attributes
    assert_requested :post, "#{GITHUB_URL}/login/oauth/access_token", times: 1
  ensure
    FreshAuthorization.define_singleton_method(:find_by!, original_lookup) if original_lookup
  end

  private

  def oauth_bundle
    %w[github_oauth_state github_oauth_verifier github_oauth_started_at fresh_authorization_id
      github_oauth_generation github_oauth_configuration_id github_oauth_credential_revision]
      .index_with { |key| request.session[key] }
  end
end
