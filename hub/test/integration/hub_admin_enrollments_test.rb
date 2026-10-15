require "test_helper"

class HubAdminEnrollmentsTest < ActionDispatch::IntegrationTest
  setup do
    @original_secret = ENV["REPLICA_BOOTSTRAP_SECRET"]
    ENV["REPLICA_BOOTSTRAP_SECRET"] = "operator-bootstrap-secret"
    @configuration = github_app_configurations.create_installed
    stub_github_oauth_user(github_id: 1002, login: "operator")
  end

  teardown do
    ENV["REPLICA_BOOTSTRAP_SECRET"] = @original_secret
  end

  test "configured deployments enroll the verified operator without repository admission or App reset" do
    state = start_enrollment(user_id: 999, hub_admin: true)
    get github_authentication_callback_path, params: { code: "code", state: }
    assert_redirected_to welcome_path
    operator = User.find_by!(github_id: 1002)
    assert operator.hub_admin?
    assert_equal operator.id, Session.last.user_id
    assert FreshAuthorization.fresh?(Session.last)
    assert_nil User.find_by(id: 999)
    assert_equal @configuration.id, GithubAppConfiguration.current.id
    event = SecurityAuditEvent.where(action: "hub_admin.enroll", outcome: "succeeded").sole
    assert_equal operator.id, event.user_id
    assert_not_includes event.attributes.to_s, "operator-bootstrap-secret"
    assert_not_includes operator.attributes.to_s, "temporary-user-token"
    get security_audit_path
    assert_response :success
  end

  test "organization App owner is never used as the operator identity" do
    assert_equal "Organization", @configuration.owner_type
    state = start_enrollment
    get github_authentication_callback_path, params: { code: "code", state: }
    assert User.find_by!(github_id: 1002).hub_admin?
    assert_nil User.find_by(github_id: @configuration.owner_github_id)
  end

  test "host authorized enrollment restores administration when the only administrator has left" do
    departed = users.create(github_id: 5001, login: "departed-admin", hub_admin: true)
    assert_equal 1, User.where(hub_admin: true).count

    state = start_enrollment
    get github_authentication_callback_path, params: { code: "code", state: }
    assert_redirected_to welcome_path
    operator = User.find_by!(github_id: 1002)
    assert operator.hub_admin?
    assert departed.reload.hub_admin?
    assert_equal @configuration.id, GithubAppConfiguration.current.id

    patch hub_admin_path(departed), params: { operation: "revoke", confirmed: "1" }
    assert_redirected_to hub_admins_path
    assert_not departed.reload.hub_admin?
    assert operator.reload.hub_admin?
    get security_audit_path
    assert_response :success
  end

  test "operators can sign in without an active installation but gain no repository permission" do
    @configuration.update!(installation_state: "removed")
    state = start_enrollment
    get github_authentication_callback_path, params: { code: "code", state: }
    assert_redirected_to welcome_path
    delete session_path
    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
    assert_redirected_to repositories_path
  end

  test "invalid secret never starts OAuth and records an anonymous denial" do
    assert_no_difference("HubAdminEnrollment.count") do
      post hub_admin_enrollment_path, params: { bootstrap_secret: "wrong", user_id: 1002 }
    end
    assert_response :not_found
    event = SecurityAuditEvent.where(action: "hub_admin.enroll").sole
    assert_equal "denied", event.outcome
    assert_nil event.user_id
    assert_not_includes event.attributes.to_s, "wrong"
  end

  test "a callback from another browser cannot enroll an operator" do
    state = start_enrollment
    other = open_session
    other.get github_authentication_callback_path, params: { code: "code", state: }
    assert_equal root_path, URI(other.response.location).path
    assert_empty User.all
    get github_authentication_callback_path, params: { code: "code", state: }
    assert User.find_by!(github_id: 1002).hub_admin?
  end

  test "expired and replayed callbacks never grant another role" do
    state = start_enrollment
    travel_to HubAdminEnrollment.last.expires_at, with_usec: true do
      get github_authentication_callback_path, params: { code: "code", state: }
      assert_redirected_to root_path
      assert_empty User.all
    end
    state = start_enrollment
    get github_authentication_callback_path, params: { code: "code", state: }
    assert_redirected_to welcome_path
    count = SecurityAuditEvent.where(action: "hub_admin.enroll", outcome: "succeeded").count
    get github_authentication_callback_path, params: { code: "code", state: }
    assert_redirected_to root_path
    assert_equal count, SecurityAuditEvent.where(action: "hub_admin.enroll", outcome: "succeeded").count
  end

  test "ordinary verified sign-in without repository access never designates an operator" do
    stub_github_installation_token
    stub_github_repositories([])
    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
    assert_redirected_to root_path
    assert_empty User.all
    assert_empty HubAdminEnrollment.all
  end

  test "enrollment cannot bypass browser anti-forgery protection" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    assert_no_difference("HubAdminEnrollment.count") do
      post hub_admin_enrollment_path, params: { bootstrap_secret: "operator-bootstrap-secret" }
    end
    assert_response :unprocessable_entity
    assert_empty User.all
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

    test "enrollment records rejected OAuth codes and service failures as different outcomes" do
      [
        [ { error: "bad_verification_code" }, "denied" ],
        [ { error: "access_denied" }, "denied" ],
        [ { error: "incorrect_client_credentials" }, "failed" ],
        [ { error: "redirect_uri_mismatch" }, "failed" ],
        [ { error: "unknown_error" }, "failed" ],
        [ {}, "failed" ],
        [ nil, "failed" ],
        [ { access_token: 77 }, "failed" ]
      ].each do |payload, outcome|
        state = start_enrollment
        stub_request(:post, "#{GITHUB_URL}/login/oauth/access_token")
          .to_return(status: 200, body: JSON.generate(payload))
        assert_difference("SecurityAuditEvent.count") do
          get github_authentication_callback_path, params: { code: "code", state: }
          assert_redirected_to root_path
        end
        assert_enrollment_failure(outcome)
      end
    end

    test "enrollment treats GitHub outages and rate limits as failures rather than identity denials" do
      [ [ :post, "#{GITHUB_URL}/login/oauth/access_token" ], [ :get, "#{GITHUB_API_URL}/user" ] ].each do |method, url|
        [ :timeout, 503, 429 ].each do |failure|
          stub_github_oauth_user(github_id: 1002, login: "operator")
          state = start_enrollment
          request = stub_request(method, url)
          if failure == :timeout
            request.to_timeout
          else
            request.to_return(status: failure, body: JSON.generate(message: "private-service-detail"))
          end
          assert_difference("SecurityAuditEvent.count") do
            get github_authentication_callback_path, params: { code: "code", state: }
            assert_redirected_to root_path
          end
          assert_enrollment_failure("failed")
        end
      end
    end

    test "enrollment keeps actual authorization rejections denied and upstream throttling failed" do
      [
        [ 401, {}, "denied" ],
        [ 403, {}, "denied" ],
        [ 403, { "X-RateLimit-Remaining" => "0" }, "failed" ]
      ].each do |status, headers, outcome|
        stub_github_oauth_user(github_id: 1002, login: "operator")
        state = start_enrollment
        stub_request(:get, "#{GITHUB_API_URL}/user")
          .to_return(status:, headers:, body: JSON.generate(message: "private-service-detail"))
        assert_difference("SecurityAuditEvent.count") do
          get github_authentication_callback_path, params: { code: "code", state: }
          assert_redirected_to root_path
        end
        assert_enrollment_failure(outcome)
      end
    end

    test "invalid enrollment state and verified identity remain denials" do
      state = start_enrollment
      get github_authentication_callback_path, params: { code: "code", state: "#{state}-invalid" }
      assert_enrollment_failure("denied")
      stub_github_oauth_user(github_id: 0, login: "")
      state = start_enrollment
      get github_authentication_callback_path, params: { code: "code", state: }
      assert_enrollment_failure("denied")
    end
  test "malformed profile responses are service failures without accepting an identity" do
    [ nil, [], 77, "private-service-detail" ].each do |profile|
      stub_github_oauth_user(github_id: 1002, login: "operator")
      state = start_enrollment
      stub_request(:get, "#{GITHUB_API_URL}/user")
        .to_return(status: 200, body: JSON.generate(profile))
      assert_difference("SecurityAuditEvent.count") do
        get github_authentication_callback_path, params: { code: "code", state: }
        assert_redirected_to root_path
      end
      assert_enrollment_failure("failed")
    end
  end

  private

  def assert_enrollment_failure(outcome)
    event = SecurityAuditEvent.where(action: "hub_admin.enroll").last
    assert_equal outcome, event.outcome
    assert_nil event.user_id
    assert_not event.repository_scoped?
    assert_not_includes event.attributes.to_s, "operator-bootstrap-secret"
    assert_not_includes event.attributes.to_s, "temporary-user-token"
    assert_not_includes event.attributes.to_s, "private-service-detail"
    assert_empty User.all
    assert_empty Session.all
  end

  def start_enrollment(**extra)
    post hub_admin_enrollment_path, params: { bootstrap_secret: "operator-bootstrap-secret" }.merge(extra)
    assert_response :redirect
    Rack::Utils.parse_query(URI(response.location).query).fetch("state")
  end
end
