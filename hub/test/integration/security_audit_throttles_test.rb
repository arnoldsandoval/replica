require "test_helper"

class SecurityAuditThrottlesTest < ActionDispatch::IntegrationTest
  setup do
    github_app_configurations.create_installed
    @repository = repositories.create
    @original_secret = ENV["REPLICA_BOOTSTRAP_SECRET"]
    ENV["REPLICA_BOOTSTRAP_SECRET"] = "operator-bootstrap-secret"
    @store = ActiveSupport::Cache::MemoryStore.new
    store = @store
    Rails.cache.define_singleton_method(:increment) do |*args, **kwargs|
      store.increment(*args, **kwargs)
    end
    travel_to Time.current.change(usec: 0)
  end

  teardown do
    Rails.cache.singleton_class.remove_method(:increment)
    ENV["REPLICA_BOOTSTRAP_SECRET"] = @original_secret
    travel_back
  end

  test "enrollment attempts share the socket budget despite changing forwarded addresses" do
    10.times do |index|
      post hub_admin_enrollment_path, params: { bootstrap_secret: "wrong" }, headers: peer_headers(index)
      assert_response :not_found
    end
    assert_equal 10, SecurityAuditEvent.where(action: "hub_admin.enroll", outcome: "denied").count
    assert_no_difference("SecurityAuditEvent.count") do
      3.times do |index|
        post hub_admin_enrollment_path, params: { bootstrap_secret: "wrong" }, headers: peer_headers(index + 10)
        assert_response :too_many_requests
      end
    end
    post hub_admin_enrollment_path, params: { bootstrap_secret: "wrong" },
      headers: { "REMOTE_ADDR" => "203.0.113.11" }
    assert_response :not_found
    travel 1.minute
    post hub_admin_enrollment_path, params: { bootstrap_secret: "wrong" }, headers: peer_headers(20)
    assert_response :not_found
  end

  test "trusted proxy chains share the resolved client budget and reset at the exact deadline" do
    headers = { "REMOTE_ADDR" => "10.0.0.5", "X-Forwarded-For" => "198.51.100.1, 203.0.113.25, 10.0.0.6" }
    10.times do |index|
      post hub_admin_enrollment_path, params: { bootstrap_secret: "wrong" },
        headers: headers.merge("X-Forwarded-For" => "198.51.100.#{index + 1}, 203.0.113.25, 10.0.0.6")
      assert_response :not_found
    end
    travel 1.minute - 1.second
    assert_no_difference("SecurityAuditEvent.count") do
      post hub_admin_enrollment_path, params: { bootstrap_secret: "wrong" }, headers: headers
      assert_response :too_many_requests
    end
    travel 1.second
    post hub_admin_enrollment_path, params: { bootstrap_secret: "wrong" }, headers: headers
    assert_response :not_found
    assert_equal "203.0.113.25", SecurityAuditEvent.where(action: "hub_admin.enroll").last.ip_address
  end

  test "authenticated operator throttles also stay out of the audit trail" do
    stub_github_oauth_user(github_id: 1002, login: "operator")
    post hub_admin_enrollment_path, params: { bootstrap_secret: "operator-bootstrap-secret" }
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
    operator = User.find_by!(github_id: 1002)
    assert operator.hub_admin?
    @store.clear

    10.times do
      post hub_admin_enrollment_path, params: { bootstrap_secret: "wrong" }, headers: peer_headers(0)
      assert_response :not_found
      assert_equal operator.id, SecurityAuditEvent.where(action: "hub_admin.enroll").last.user_id
    end
    assert_no_difference("SecurityAuditEvent.count") do
      3.times do
        post hub_admin_enrollment_path, params: { bootstrap_secret: "wrong" }, headers: peer_headers(0)
        assert_response :too_many_requests
      end
    end
    travel 1.minute
    assert_difference("HubAdminEnrollment.count") do
      post hub_admin_enrollment_path, params: { bootstrap_secret: "operator-bootstrap-secret" }, headers: peer_headers(0)
      assert_response :found
    end
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    assert_difference("SecurityAuditEvent.where(action: 'hub_admin.enroll', outcome: 'succeeded').count") do
      get github_authentication_callback_path, params: { code: "code", state: }
      assert_redirected_to repositories_path
    end
  end

  test "pairing creation audits admitted requests but never repeated local throttles" do
    10.times do |index|
      post canvas_api_pairings_path, params: { repository: @repository.name_with_owner },
        headers: peer_headers(index), as: :json
      assert_response :created
    end
    assert_equal 10, SecurityAuditEvent.where(action: "canvas_pairing.create", outcome: "succeeded").count
    assert_equal [ @repository.id ], SecurityAuditEvent.where(action: "canvas_pairing.create").distinct.pluck(:repository_id)
    assert_equal [ "203.0.113.10" ], SecurityAuditEvent.where(action: "canvas_pairing.create").distinct.pluck(:ip_address)
    assert_no_difference("SecurityAuditEvent.count") do
      3.times do |index|
        post canvas_api_pairings_path, params: { repository: @repository.name_with_owner },
          headers: peer_headers(index + 10), as: :json
        assert_response :too_many_requests
      end
    end
    travel 1.minute
    assert_difference("SecurityAuditEvent.count") do
      post canvas_api_pairings_path, params: { repository: @repository.name_with_owner },
        headers: peer_headers(20), as: :json
      assert_response :created
    end
  end

  test "pairing polling audits unidentified denials but never repeated local throttles" do
    60.times do |index|
      post canvas_api_pairing_token_path, params: { device_code: "A" * 43 },
        headers: peer_headers(index), as: :json
      assert_response :success
    end
    assert_equal 60, SecurityAuditEvent.where(action: "canvas_pairing.consume", outcome: "denied").count
    assert_equal [ nil ], SecurityAuditEvent.where(action: "canvas_pairing.consume").distinct.pluck(:user_id)
    assert_equal [ false ], SecurityAuditEvent.where(action: "canvas_pairing.consume").distinct.pluck(:repository_scoped)
    assert_no_difference("SecurityAuditEvent.count") do
      3.times do |index|
        post canvas_api_pairing_token_path, params: { device_code: "A" * 43 },
          headers: peer_headers(index + 60), as: :json
        assert_response :too_many_requests
      end
    end
  end

  test "renewal and disconnect share their existing allowance without auditing throttles" do
    30.times do |index|
      post canvas_api_connection_renewal_path, params: { refresh_token: "rr_#{"A" * 43}" },
        headers: peer_headers(index * 2), as: :json
      assert_response :unauthorized
      delete canvas_api_connection_renewal_path, params: { refresh_token: "rr_#{"A" * 43}" },
        headers: peer_headers(index * 2 + 1), as: :json
      assert_response :no_content
    end
    assert_equal 60, SecurityAuditEvent.where(action: %w[canvas_connection.renew canvas_connection.revoke]).count
    assert_equal [ nil ], SecurityAuditEvent.where(action: %w[canvas_connection.renew canvas_connection.revoke]).distinct.pluck(:user_id)
    assert_no_difference("SecurityAuditEvent.count") do
      3.times do |index|
        post canvas_api_connection_renewal_path, params: { refresh_token: "rr_#{"A" * 43}" },
          headers: peer_headers(index + 60), as: :json
        assert_response :too_many_requests
        delete canvas_api_connection_renewal_path, params: { refresh_token: "rr_#{"A" * 43}" },
          headers: peer_headers(index + 63), as: :json
        assert_response :too_many_requests
      end
    end
  end

  test "trusted proxy clients keep independent existing canvas allowances" do
    [
      [ :post, canvas_api_pairings_path, { repository: @repository.name_with_owner }, 10, :created ],
      [ :post, canvas_api_pairing_token_path, { device_code: "A" * 43 }, 60, :success ],
      [ :post, canvas_api_connection_renewal_path, { refresh_token: "rr_#{"A" * 43}" }, 60, :unauthorized ],
      [ :delete, canvas_api_connection_renewal_path, { refresh_token: "rr_#{"A" * 43}" }, 60, :no_content ]
    ].each do |method, path, params, limit, status|
      @store.clear
      limit.times do |index|
        public_send method, path, params:, as: :json,
          headers: { "REMOTE_ADDR" => "10.0.0.5", "X-Forwarded-For" => "198.51.100.#{index + 1}, 203.0.113.25, 10.0.0.6" }
        assert_response status
      end
      assert_no_difference("SecurityAuditEvent.count") do
        public_send method, path, params:, as: :json,
          headers: { "REMOTE_ADDR" => "10.0.0.5", "X-Forwarded-For" => "198.51.100.250, 203.0.113.25, 10.0.0.6" }
        assert_response :too_many_requests
      end
      assert_difference("SecurityAuditEvent.count") do
        public_send method, path, params:, as: :json,
          headers: { "REMOTE_ADDR" => "10.0.0.5", "X-Forwarded-For" => "203.0.113.26, 10.0.0.6" }
        assert_response status
      end
      assert_equal "203.0.113.26", SecurityAuditEvent.last.ip_address
    end
  end

  private

  def peer_headers(index)
    { "REMOTE_ADDR" => "203.0.113.10", "X-Forwarded-For" => "198.51.100.#{index + 1}" }
  end
end
