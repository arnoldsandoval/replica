require "test_helper"

class SecurityActionsAuditTest < ActionDispatch::IntegrationTest
  setup do
    SharingSetting.create!(id: 1, public_sharing_enabled: true)
    github_app_configurations.create_installed
    @payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ @payload ], permissions: { 2001 => "admin" })
    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
    @user = User.find_by!(github_id: 1001)
    @repository = Repository.find_by!(github_id: 2001)
    @prototype = prototypes.create(repository: @repository)
    @build = builds.create_successful(prototype: @prototype)
    @shares_path = repository_prototype_share_links_path(@repository.route_id, @prototype)
    @headers = {
      "REMOTE_ADDR" => "203.0.113.12", "X-Forwarded-For" => "198.51.100.99",
      "User-Agent" => "Macintosh Chrome/123 never-retain-this-secret"
    }
  end

  test "browser share creation and deletion retain the actor source and nonsecret device snapshot" do
    post @shares_path, params: { share_link: { build_number: 1, label: "private-label" } }, headers: @headers
    assert_response :see_other
    link = ShareLink.last
    event = audit("share_link.create", "succeeded")
    assert_equal @user.id, event.user_id
    assert_equal "203.0.113.12", event.ip_address
    assert_equal "desktop", event.context.fetch("device_family")
    assert_equal "chrome", event.context.fetch("browser_family")
    assert_not_includes event.attributes.to_s, link.public_id
    assert_not_includes event.attributes.to_s, "private-label"
    assert_not_includes event.attributes.to_s, "never-retain-this-secret"
    delete repository_prototype_share_link_path(@repository.route_id, @prototype, link), headers: @headers
    assert_response :see_other
    assert_equal link.id, audit("share_link.delete", "succeeded").context.fetch("share_link_id")
    delete session_path
    assert_not Session.exists?(event.context.fetch("session_id"))
    assert_equal "chrome", event.reload.context.fetch("browser_family")
  end

  test "trusted proxy chains use Rails resolution instead of a client-supplied leftmost IP" do
    headers = @headers.merge("REMOTE_ADDR" => "10.0.0.5",
      "X-Forwarded-For" => "198.51.100.99, 203.0.113.25, 10.0.0.6")
    post @shares_path, params: { share_link: { build_number: 1, label: "Example" } }, headers: headers
    assert_equal "203.0.113.25", audit("share_link.create", "succeeded").ip_address
  end

  test "invalid and denied browser share changes create distinct outcomes without retaining input" do
    post @shares_path, params: { share_link: { build_number: 1, label: "private-label", expiration: "invalid" } }
    assert_response :see_other
    assert_equal @user.id, audit("share_link.create", "failed").user_id
    stub_github_permissions([ @payload ], { 2001 => nil })
    post @shares_path, params: { share_link: { build_number: 1, label: "private-label" } }
    assert_response :not_found
    audit("share_link.create", "denied")
    assert_empty ShareLink.all
    delete session_path
    post @shares_path, params: { share_link: { build_number: 1, label: "private-label" } }
    assert_redirected_to root_path
    event = SecurityAuditEvent.where(action: "share_link.create").last
    assert_nil event.user_id
    assert_nil event.repository_id
    assert_equal "denied", event.outcome
  end

  test "analytics changes and validation failures never retain provider secrets" do
    path = repository_analytics_destinations_path(@repository.route_id)
    attributes = { provider: "segment", region: "us", history: "new",
      event_types: [ "build_published" ], credentials: { write_key: "private-provider-secret" } }
    post path, params: { destination: attributes }
    destination = @repository.analytics_destinations.sole
    audit("analytics_destination.create", "succeeded")
    path = repository_analytics_destination_path(@repository.route_id, destination)
    patch path, params: { destination: attributes.merge(region: "eu") }
    audit("analytics_destination.update", "succeeded")
    patch path, params: { operation: "pause" }
    audit("analytics_destination.pause", "succeeded")
    patch path, params: { operation: "resume" }
    audit("analytics_destination.resume", "succeeded")
    patch path, params: { destination: attributes.merge(region: "invalid") }
    audit("analytics_destination.update", "failed")
    delete path
    audit("analytics_destination.delete", "succeeded")
    assert_not_includes SecurityAuditEvent.all.map(&:attributes).to_s, "private-provider-secret"
  end

  test "canvas pairing renewal and both disconnect APIs audit scoped decisions without credentials" do
    post canvas_api_pairings_path, params: { repository: "github/prototype", renewable: true }, as: :json
    pairing = JSON.parse(response.body)
    assert_nil audit("canvas_pairing.create", "succeeded").user_id
    post approve_canvas_pairing_path(pairing.fetch("userCode"))
    audit("canvas_pairing.approve", "succeeded")
    post canvas_api_pairing_token_path, params: { device_code: pairing.fetch("deviceCode") }, as: :json
    credentials = JSON.parse(response.body)
    audit("canvas_pairing.consume", "succeeded")
    post canvas_api_connection_renewal_path, params: { refresh_token: pairing.fetch("refreshToken") }, as: :json
    renewed = JSON.parse(response.body)
    audit("canvas_connection.renew", "succeeded")
    stub_github_permissions([ @payload ], { 2001 => nil })
    post canvas_api_connection_renewal_path, params: { refresh_token: pairing.fetch("refreshToken") }, as: :json
    assert_response :forbidden
    assert_equal @user.id, audit("canvas_connection.renew", "denied").user_id
    delete canvas_api_connection_path, headers: { "Authorization" => "Bearer #{renewed.fetch('accessToken')}" }
    assert_response :no_content
    audit("canvas_connection.revoke", "succeeded")
    data = SecurityAuditEvent.all.map(&:attributes).to_s
    [ pairing.fetch("deviceCode"), pairing.fetch("userCode"), pairing.fetch("refreshToken"),
      credentials.fetch("accessToken"), renewed.fetch("accessToken") ].each do |secret|
      assert_not_includes data, secret
    end
  end

    test "missing analytics input records one scoped validation failure" do
      assert_no_difference("Analytics::Destination.count") do
        assert_difference("SecurityAuditEvent.count") do
          post repository_analytics_destinations_path(@repository.route_id)
          assert_response :see_other
        end
      end
      event = audit("analytics_destination.create", "failed")
      assert_equal @user.id, event.user_id
    end

    test "known expired and consumed pairings retain anonymous repository attribution" do
      pairing, device = CanvasPairing.start!(@repository)
      travel_to pairing.expires_at, with_usec: true do
        assert_difference("SecurityAuditEvent.count") do
          post canvas_api_pairing_token_path, params: { device_code: device }, as: :json
          assert_equal "expired", JSON.parse(response.body).fetch("status")
        end
        event = audit("canvas_pairing.consume", "denied")
        assert_nil event.user_id
        assert event.repository_scoped?
        assert_equal pairing.id, event.context.fetch("canvas_pairing_id")
        assert_not_includes event.attributes.to_s, device
        assert_not_includes event.attributes.to_s, pairing.user_code
      end

      pairing, device = CanvasPairing.start!(@repository)
      pairing.approve!(@user, browser_session: @user.sessions.sole)
      CanvasPairing.consume(device)
      assert_difference("SecurityAuditEvent.count") do
        post canvas_api_pairing_token_path, params: { device_code: device }, as: :json
        assert_equal "expired", JSON.parse(response.body).fetch("status")
      end
      event = audit("canvas_pairing.consume", "denied")
      assert_nil event.user_id
      assert_equal pairing.id, event.context.fetch("canvas_pairing_id")
      assert_not_includes event.attributes.to_s, device
    end

    test "unidentified pairing proofs are global while known permission denials are recorded once" do
      [ "malformed", "A" * 43 ].each do |device|
        assert_difference("SecurityAuditEvent.count") do
          post canvas_api_pairing_token_path, params: { device_code: device }, as: :json
        end
        event = SecurityAuditEvent.where(action: "canvas_pairing.consume").last
        assert_equal "denied", event.outcome
        assert_not event.repository_scoped?
        assert_nil event.repository_id
        assert_nil event.user_id
        assert_not event.context.key?("canvas_pairing_id")
      end

      pairing, device = CanvasPairing.start!(@repository)
      pairing.approve!(@user, browser_session: @user.sessions.sole)
      stub_github_permissions([ @payload ], { 2001 => nil })
      assert_difference("SecurityAuditEvent.count") do
        post canvas_api_pairing_token_path, params: { device_code: device }, as: :json
        assert_equal "denied", JSON.parse(response.body).fetch("status")
      end
      assert_equal pairing.id, audit("canvas_pairing.consume", "denied").context.fetch("canvas_pairing_id")
    end

  test "canvas share creation and deletion use the same audit contract as the browser" do
    pairing, device, = CanvasPairing.start!(@repository)
    pairing.approve!(@user, browser_session: @user.sessions.create!)
    _, credentials = CanvasPairing.consume(device)
    headers = { "Authorization" => "Bearer #{credentials.fetch(:secret)}" }
    path = canvas_api_share_links_path(repository_github_id: @repository.route_id, prototype_id: @prototype.id)
    post path, params: { share_link: { build_number: 1, label: "Example" } }, headers:, as: :json
    assert_response :created
    event = audit("share_link.create", "succeeded")
    assert_equal "canvas", event.context.fetch("source")
    assert_equal credentials.fetch(:grant).id, event.context.fetch("canvas_grant_id")
    delete canvas_api_share_link_path(repository_github_id: @repository.route_id,
      prototype_id: @prototype.id, id: ShareLink.last.id), headers: headers
    assert_response :no_content
    audit("share_link.delete", "succeeded")
  end

  test "setup denials are global and do not retain bootstrap or callback state" do
    delete session_path
    post setup_path, params: { bootstrap_secret: "private-bootstrap-secret" }, headers: @headers
    assert_response :not_found
    event = SecurityAuditEvent.where(action: "github_app_setup.authorize").last
    assert_equal "denied", event.outcome
    assert_nil event.user_id
    assert_nil event.repository_id
    assert_equal "203.0.113.12", event.ip_address
    assert_not_includes event.attributes.to_s, "private-bootstrap-secret"
    get callback_setup_path, params: { code: "private-code", state: "private-state" }
    assert_response :not_found
    event = SecurityAuditEvent.where(action: "github_app_setup.exchange").last
    assert_equal "denied", event.outcome
    assert_not_includes event.attributes.to_s, "private-state"
  end

  test "request logging filters enrollment proofs and credentials without hiding safe identifiers" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    secret_keys = %w[
      bootstrap_secret hub_admin_enrollment_proof proof access_token refresh_token
      device_code user_code client_secret private_key pem state authorization cookie_token
    ]
    input = secret_keys.index_with { |key| "private-value-for-#{key}" }
    input["repository_id"] = @repository.id
    filtered = filter.filter(input)

    secret_keys.each { |key| assert_equal "[FILTERED]", filtered.fetch(key) }
    assert_equal @repository.id, filtered.fetch("repository_id")
    secret_keys.each { |key| assert_not_includes filtered.to_s, input.fetch(key) }
  end

  private

  def audit(action, outcome)
    event = SecurityAuditEvent.where(action:).last
    assert_equal outcome, event.outcome
    assert_equal @repository.id, event.repository_id
    event
  end
end
