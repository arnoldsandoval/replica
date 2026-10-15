require "test_helper"
require "timeout"

# Committed connections keep a writer from clearing the subscriber's SQL cache.
class ReviewCommentsRevocationTest < ActionCable::Channel::TestCase
  tests ReviewCommentsChannel
  self.use_transactional_tests = false

  setup do
    @audit_ids = SecurityAuditEvent.ids
    @configuration = github_app_configurations.create_installed
    @user = users.create(github_id: 9101, login: "revocation-admin", hub_admin: true)
    @session = @user.sessions.create!(fresh_authorized_at: Time.current)
    @repository = repositories.create(github_id: 9201, name_with_owner: "github/revocation")
    @prototype = prototypes.create(repository: @repository)
    stub_github_installation_token
    Rails.cache.clear
  end

  teardown do
    SecurityAuditEvent.where.not(id: @audit_ids).delete_all
    @prototype.delete
    @repository.delete
    Session.where(user_id: @user.id).delete_all
    @user.delete
    @configuration.delete
    SessionRevocation.delete_all
    Rails.cache.clear
  end

  test "a cached browser credential cannot subscribe after another connection ends it" do
    assert_revoked_subscription
  end

  test "a cached canvas credential cannot subscribe after another connection revokes it" do
    travel_to Time.current, with_usec: true do
      grant = CanvasGrant.create! \
        user: @user,
        repository: @repository,
        token_digest: Digest::SHA256.hexdigest("cached-canvas"),
        expires_at: 7.days.from_now
      assert_revoked_subscription(canvas_grant: grant)
    end
  end

  private

  # The transport is stubbed, but both checks use the real credential predicate.
  def assert_revoked_subscription(canvas_grant: nil)
    live_connection = ApplicationCable::Connection.new(ActionCable.server, {})
    live_connection.current_user = @user
    live_connection.instance_variable_set(:@browser_session_id, @session.id)
    live_connection.instance_variable_set(:@canvas_grant_id, canvas_grant&.id)
    stub_connection current_user: @user, canvas_grant_id: canvas_grant&.id
    connection.define_singleton_method(:credential_active?) { live_connection.credential_active? }
    credentials = if canvas_grant
      CanvasGrant.authenticated.where(id: canvas_grant.id, user_id: @user.id)
    else
      Session.where(id: @session.id, user_id: @user.id)
    end
    reached_github = Queue.new
    finish = Queue.new
    permission_request = stub_request \
      :get,
      "#{GITHUB_API_URL}/repos/#{@repository.name_with_owner}/collaborators/#{@user.login}/permission"
    permission_request.to_return do
      checking = ApplicationRecord.connection
      assert checking.query_cache_enabled
      assert credentials.exists?
      reached_github << checking.object_id
      finish.pop
      assert credentials.exists?
      { status: 200, body: { permission: "pull", user: { id: @user.github_id } }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end
    subscriber = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ApplicationRecord.cache do
          subscribe repositoryId: @repository.route_id, prototypeId: @prototype.id
        end
      end
    end
    checking_id = Timeout.timeout(5) { reached_github.pop }
    ActiveRecord::Base.connection_pool.with_connection do |writer|
      assert_not_equal checking_id, writer.object_id
      SessionRevocation.end_all!(actor: @user, browser_session: @session)
    end
    finish << true
    Timeout.timeout(5) { subscriber.value }

    assert subscription.rejected?
    assert_no_streams
    assert_empty Session.where(id: @session.id)
    assert canvas_grant.reload.revoked_at if canvas_grant
  ensure
    finish << true if finish
    subscriber&.join
  end
end
