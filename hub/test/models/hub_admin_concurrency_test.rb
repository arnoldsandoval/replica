require "test_helper"

# Uses committed records and separate connections, not Rails's shared test transaction.
class HubAdminConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @first = users.create(github_id: 9001, login: "first-admin", hub_admin: true)
    @second = users.create(github_id: 9002, login: "second-admin", hub_admin: true)
    @target = users.create(github_id: 9003, login: "target-user")
    @first_session = @first.sessions.create!(fresh_authorized_at: Time.current)
    @second_session = @second.sessions.create!(fresh_authorized_at: Time.current)
  end

  teardown do
    ids = [ @first, @second, @target ].compact.map(&:id)
    SecurityAuditEvent.where(user_id: ids).delete_all
    Session.where(user_id: ids).delete_all
    User.where(id: ids).delete_all
  end

  test "simultaneous self removals preserve exactly one administrator" do
    ready = Queue.new
    start = Queue.new
    connections = Queue.new
    requests = [ [ @first, @first_session ], [ @second, @second_session ] ].map do |actor, session|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connections << connection.object_id
          ready << true
          start.pop
          actor.change_hub_admin!(actor:, browser_session: session, operation: "revoke")
          :succeeded
        rescue User::AdminRoleChangeDenied => error
          error.reason
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }

    assert_equal [ :last_admin, :succeeded ], requests.map(&:value).sort
    assert_equal 2, 2.times.map { connections.pop }.uniq.length
    assert_equal 1, User.where(id: [ @first.id, @second.id ], hub_admin: true).count
    assert_equal 1, SecurityAuditEvent.where(action: "hub_admin.revoke", outcome: "succeeded").count
  ensure
    requests&.each(&:join)
  end

  test "a role check waiting behind revocation sees the committed normal role" do
    revoked = Queue.new
    attempted = Queue.new
    finish = Queue.new
    revocation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          @second.change_hub_admin!(actor: @first, browser_session: @first_session, operation: "revoke")
          revoked << true
          finish.pop
        end
      end
    end
    revoked.pop
    designation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        attempted << true
        @target.change_hub_admin!(actor: @second, browser_session: @second_session, operation: "designate")
        :succeeded
      rescue User::AdminRoleChangeDenied => error
        error.reason
      end
    end
    attempted.pop
    finish << true
    revocation.value

    assert_equal :not_authorized, designation.value
    assert_not @target.reload.hub_admin?
    assert_not @second.reload.hub_admin?
    assert_equal 0, SecurityAuditEvent.where(action: "hub_admin.designate").count
  ensure
    finish << true if finish
    [ revocation, designation ].compact.each(&:join)
  end
end
