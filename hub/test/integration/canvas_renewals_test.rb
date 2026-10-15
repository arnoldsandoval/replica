require "test_helper"

class CanvasRenewalsTest < ActionDispatch::IntegrationTest
  setup do
    host! "replica.localhost:19500"
    github_app_configurations.create_installed
    stub_github_sign_in \
      repositories: [ repository_payload(2001, "github/prototype") ],
      permissions: { 2001 => "admin" }
    sign_in_to_hub
  end

  test "pairs before branch discovery and renews the stable connection after seven days" do
    refresh_token, approved = renewable_connection
    grant = CanvasGrant.find(approved.fetch("connectionId"))
    deadline = grant.inactive_at
    assert_empty grant.repository.prototypes
    assert_not_includes grant.attributes.to_s, refresh_token
    assert_equal 30.days, grant.inactive_at - grant.last_active_at
    get canvas_api_connection_path,
      headers: { "Authorization" => "Bearer #{approved.fetch('accessToken')}" }
    assert_response :success
    assert_equal true, JSON.parse(response.body).fetch("canPublish")

    travel 7.days + 1.second do
      stub_github_installation_token
      assert_nil CanvasGrant.authenticate(approved.fetch("accessToken"))
      CanvasGrant.clear_expired!
      assert CanvasGrant.exists?(grant.id)
      post canvas_api_connection_renewal_path, params: { refresh_token: }, as: :json
      assert_response :success
      renewed = JSON.parse(response.body)
      assert_equal grant.id, renewed.fetch("connectionId")
      assert_equal deadline, grant.reload.inactive_at
      assert CanvasGrant.authenticate(renewed.fetch("accessToken"))
      assert_nil grant.fresh_authorized_at
      assert_equal "[FILTERED]", request.filtered_parameters.fetch("refresh_token")
      assert_nil CanvasGrant.authenticate(approved.fetch("accessToken"))

      post canvas_api_connection_renewal_path, params: { refresh_token: }, as: :json
      assert_response :success
      assert_equal grant.id, JSON.parse(response.body).fetch("connectionId")
      assert_equal 1, CanvasGrant.count

      get canvas_connections_path, as: :json
      assert_equal 1, JSON.parse(response.body).fetch("data").fetch("grants").size
    end
  end

  test "App credentials changed during repository verification cannot rotate a live access token" do
    refresh_token, approved = renewable_connection
    grant = CanvasGrant.find(approved.fetch("connectionId"))
    before = grant.token_digest
    stub_request(:get, "#{GITHUB_API_URL}/repos/#{grant.repository.name_with_owner}/collaborators/#{grant.user.login}/permission")
      .to_return do
        configuration = GithubAppConfiguration.current
        configuration.update!(credential_revision: configuration.credential_revision + 1)
        { status: 200, body: JSON.generate(permission: "admin", user: { id: grant.user.github_id }) }
      end
    post canvas_api_connection_renewal_path, params: { refresh_token: }, as: :json
    assert_response :unauthorized
    assert_equal before, grant.reload.token_digest
    assert_nil grant.revoked_at
    assert_nil grant.fresh_authorized_at
  end

  test "interactive use extends inactivity while polling and renewal do not" do
    refresh_token, approved = renewable_connection
    grant = CanvasGrant.find(approved.fetch("connectionId"))
    deadline = grant.inactive_at
    headers = { "Authorization" => "Bearer #{approved.fetch('accessToken')}" }
    travel 1.day do
      stub_github_installation_token
      get canvas_api_connection_path, headers: headers
      assert_response :success
      post canvas_api_cable_ticket_path, headers: headers
      assert_response :success
      assert_equal deadline, grant.reload.inactive_at
      assert_equal (grant.last_active_at + 30.days).to_i, grant.inactive_at.to_i

      patch canvas_api_connection_path, headers: headers
      assert_response :no_content
      assert_equal Time.current.to_i, grant.reload.last_active_at.to_i
      assert_equal 30.days.from_now.to_i, grant.inactive_at.to_i
      post canvas_api_connection_renewal_path, params: { refresh_token: }, as: :json
      assert_response :success
      assert_equal 30.days.from_now.to_i, grant.reload.inactive_at.to_i
    end
  end

  test "the exact inactivity boundary rejects access, activity and refresh" do
    refresh_token, approved = renewable_connection
    grant = CanvasGrant.find(approved.fetch("connectionId"))
    deadline = grant.inactive_at
    travel_to deadline - 1.second, with_usec: true do
      stub_github_installation_token
      post canvas_api_connection_renewal_path, params: { refresh_token: }, as: :json
      assert_response :success
      approved = JSON.parse(response.body)
      assert_equal deadline.to_i, Time.iso8601(approved.fetch("expiresAt")).to_i
    end
    travel_to deadline, with_usec: true do
      headers = { "Authorization" => "Bearer #{approved.fetch('accessToken')}" }
      get canvas_api_connection_path, headers: headers
      assert_response :unauthorized
      patch canvas_api_connection_path, headers: headers
      assert_response :unauthorized
      post canvas_api_connection_renewal_path, params: { refresh_token: }, as: :json
      assert_response :unauthorized
      assert_equal deadline, grant.reload.inactive_at
      CanvasGrant.clear_expired!
      assert_not CanvasGrant.exists?(grant.id)
    end
  end

  test "revocation wins over a renewal holding a stale model instance" do
    refresh_token, approved = renewable_connection
    stale = CanvasGrant.for_refresh(refresh_token)
    grant = CanvasGrant.find(approved.fetch("connectionId"))
    grant.revoke!
    assert_raises(CanvasGrant::Expired) { stale.renew! }
    assert_raises(CanvasGrant::Expired) { stale.record_activity! }
    post canvas_api_connection_renewal_path, params: { refresh_token: }, as: :json
    assert_response :unauthorized
    assert_nil CanvasGrant.authenticate(approved.fetch("accessToken"))
  end

  test "fresh denial and a GitHub outage both block renewal without extending activity" do
    refresh_token, approved = renewable_connection
    grant = CanvasGrant.find(approved.fetch("connectionId"))
    before = grant.attributes
    stub_github_permissions([ repository_payload(2001, "github/prototype") ], { 2001 => "none" })
    post canvas_api_connection_renewal_path, params: { refresh_token: }, as: :json
    assert_response :forbidden
    assert_equal before, grant.reload.attributes
    get canvas_api_connection_path, headers: { "Authorization" => "Bearer #{approved.fetch('accessToken')}" }
    assert_response :forbidden

    stub_request(:get, "https://api.github.com/repos/github/prototype/collaborators/octocat/permission")
      .to_return(status: 503)
    post canvas_api_connection_renewal_path, params: { refresh_token: }, as: :json
    assert_response :service_unavailable
    assert_equal before, grant.reload.attributes
  end

  test "the saved refresh proof recovers a lost consumption response without another approval" do
    refresh_token, approved = renewable_connection
    post canvas_api_connection_renewal_path, params: { refresh_token: }, as: :json
    assert_response :success
    assert_equal approved.fetch("connectionId"), JSON.parse(response.body).fetch("connectionId")
    assert_equal 1, CanvasPairing.count
    assert_equal 1, CanvasGrant.count
    delete canvas_api_connection_renewal_path, params: { refresh_token: }, as: :json
    assert_response :no_content
    assert CanvasGrant.first.revoked_at
  end

  test "legacy approval remains nonrenewable until its existing expiry" do
    _, approval = renewable_connection(renewable: false)
    token = approval.fetch("accessToken")
    grant = CanvasGrant.authenticate(token)
    assert_nil grant.refresh_token_digest
    patch canvas_api_connection_path, headers: { "Authorization" => "Bearer #{token}" }
    assert_response :no_content
    assert_nil grant.reload.inactive_at
    travel_to grant.expires_at, with_usec: true do
      assert_nil CanvasGrant.authenticate(token)
      CanvasGrant.clear_expired!
      assert_not CanvasGrant.exists?(grant.id)
    end
  end

  private

  def renewable_connection(renewable: true)
    post canvas_api_pairings_path, params: { repository: "github/prototype", renewable: }, as: :json
    pairing = JSON.parse(response.body)
    post approve_canvas_pairing_path(pairing.fetch("userCode"))
    post canvas_api_pairing_token_path, params: { device_code: pairing.fetch("deviceCode") }, as: :json
    [ pairing["refreshToken"], JSON.parse(response.body) ]
  end
end
