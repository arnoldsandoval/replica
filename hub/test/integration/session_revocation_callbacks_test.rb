require "test_helper"
require "timeout"

# Committed records expose cutoffs between GitHub checks and credential issuance.
class SessionRevocationCallbacksTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    @audit_ids = SecurityAuditEvent.ids
    @original_secret = ENV["REPLICA_BOOTSTRAP_SECRET"]
    ENV["REPLICA_BOOTSTRAP_SECRET"] = "operator-bootstrap-secret"
    @configuration = github_app_configurations.create_installed
    @actor = users.create(github_id: 9101, login: "revocation-admin", hub_admin: true)
    @session = @actor.sessions.create!(fresh_authorized_at: Time.current)
    @repository = repositories.create(github_id: 9201, name_with_owner: "github/revocation")
    @prototype = prototypes.create(repository: @repository)
    @build = builds.create_successful(prototype: @prototype)
    stub_github_oauth_user(github_id: 9102, login: "pending-operator")
    host! "replica.localhost:19500"
    Rails.cache.clear
  end

  teardown do
    ENV["REPLICA_BOOTSTRAP_SECRET"] = @original_secret
    SecurityAuditEvent.where.not(id: @audit_ids).delete_all
    Analytics::Event.where(repository_id: @repository.id).delete_all
    @build.delete
    @prototype.delete
    @repository.delete
    ids = User.where(github_id: [ 9101, 9102 ]).ids
    Session.where(user_id: ids).delete_all
    User.where(id: ids).delete_all
    HubAdminEnrollment.delete_all
    @configuration.delete
    SessionRevocation.delete_all
    Rails.cache.clear
  end

  test "a cutoff before enrollment records one denial and consumes the browser flow" do
    state = start_enrollment
    checking_id = ApplicationRecord.connection.object_id
    revocation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |writer|
        SessionRevocation.end_all!(actor: @actor, browser_session: @session)
        writer.object_id
      end
    end
    assert_not_equal checking_id, Timeout.timeout(5) { revocation.value }

    get github_authentication_callback_path, params: { code: "code", state: }

    assert_response :see_other
    assert_redirected_to root_path
    event = SecurityAuditEvent.where(action: "hub_admin.enroll").sole
    assert_equal "denied", event.outcome
    assert_nil event.user_id
    assert_nil User.find_by(github_id: 9102)
    assert_empty Session.all
    assert_not_requested :post, "#{GITHUB_URL}/login/oauth/access_token"

    get github_authentication_callback_path, params: { code: "code", state: }
    assert_redirected_to root_path
    assert_equal 1, SecurityAuditEvent.where(action: "hub_admin.enroll").count
  ensure
    revocation&.join
  end

  test "committed enrollment stays succeeded when the cutoff rejects only Session issuance" do
    state = start_enrollment
    reached_issuance = Queue.new
    finish = Queue.new
    original = GithubAuthenticationsController.instance_method(:start_new_session_for)
    GithubAuthenticationsController.define_method(:start_new_session_for) do |user, **options|
      reached_issuance << ApplicationRecord.connection.object_id
      finish.pop
      original.bind_call(self, user, **options)
    end
    GithubAuthenticationsController.send(:private, :start_new_session_for)
    callback = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ApplicationRecord.cache do
          get github_authentication_callback_path, params: { code: "code", state: }
        end
      end
    end
    checking_id = Timeout.timeout(5) { reached_issuance.pop }
    ActiveRecord::Base.connection_pool.with_connection do |writer|
      assert_not_equal checking_id, writer.object_id
      operator = User.find_by!(github_id: 9102)
      assert operator.hub_admin?
      assert_equal operator.id, SecurityAuditEvent.where(action: "hub_admin.enroll").sole.user_id
      SessionRevocation.end_all!(actor: @actor, browser_session: @session)
    end
    finish << true
    Timeout.timeout(5) { callback.value }

    assert_response :see_other
    assert_redirected_to root_path
    assert User.find_by!(github_id: 9102).hub_admin?
    assert_equal [ "succeeded" ], SecurityAuditEvent.where(action: "hub_admin.enroll").pluck(:outcome)
    assert_empty Session.all
  ensure
    finish << true if finish
    callback&.join
    GithubAuthenticationsController.send(:remove_method, :start_new_session_for) if original
  end

  test "preview issuance returns not found after another connection deletes its cached Session" do
    stub_github_oauth_user(github_id: @actor.github_id, login: @actor.login)
    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
    assert_redirected_to welcome_path
    browser_session = @actor.sessions.order(:id).last
    stub_github_installation_token
    reached_github = Queue.new
    finish = Queue.new
    permission_request = stub_request \
      :get,
      "#{GITHUB_API_URL}/repos/#{@repository.name_with_owner}/collaborators/#{@actor.login}/permission"
    permission_request.to_return do
      checking = ApplicationRecord.connection
      assert checking.query_cache_enabled
      assert_equal browser_session.id, Session.find(browser_session.id).id
      reached_github << checking.object_id
      finish.pop
      assert_equal browser_session.id, Session.find(browser_session.id).id
      { status: 200, body: { permission: "pull", user: { id: @actor.github_id } }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end
    authorization = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ApplicationRecord.cache { get preview_build_authorization_path(@build.id) }
      end
    end
    checking_id = Timeout.timeout(5) { reached_github.pop }
    ActiveRecord::Base.connection_pool.with_connection do |writer|
      assert_not_equal checking_id, writer.object_id
      SessionRevocation.end_all!(actor: @actor, browser_session: @session)
    end
    finish << true
    Timeout.timeout(5) { authorization.value }

    assert_response :not_found
    assert_empty response.body
    assert_empty PreviewGrant.all
    assert_empty Session.all
  ensure
    finish << true if finish
    authorization&.join
  end

  private

  def start_enrollment
    post hub_admin_enrollment_path, params: { bootstrap_secret: "operator-bootstrap-secret" }
    assert_response :redirect
    Rack::Utils.parse_query(URI(response.location).query).fetch("state")
  end
end
