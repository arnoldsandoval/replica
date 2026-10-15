require "test_helper"
require "timeout"

class CopilotConnectionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @admin = users.create(github_id: 9941, login: "copilot-admin", hub_admin: true)
    @session = @admin.sessions.create!(fresh_authorized_at: Time.current)
    @other = users.create(github_id: 9942, login: "other-copilot-admin", hub_admin: true)
    @other_session = @other.sessions.create!(fresh_authorized_at: Time.current)
    @previous_token = Rails.configuration.x.copilot_token
    Rails.configuration.x.copilot_token = "copilot-user-token"
    @connection = CopilotConnection.create! \
      user: @admin,
      token_digest: CopilotConnection.digest("copilot-user-token"),
      verified_at: Time.current
  end

  teardown do
    SecurityAuditEvent.where(user_id: [ @admin.id, @other.id ]).delete_all
    CopilotConnection.where(user_id: [ @admin.id, @other.id ]).delete_all
    CopilotConnectionState.delete_all
    Session.where(user_id: [ @admin.id, @other.id ]).delete_all
    User.where(id: [ @admin.id, @other.id ]).delete_all
    Rails.configuration.x.copilot_token = @previous_token
  end

  test "a successful recheck cannot recreate a connection another administrator disconnected" do
    outcome = during_successful_check do
      CopilotConnection.disconnect!(actor: @other, browser_session: @other_session)
    end

    assert_equal :connection_changed, outcome
    assert_nil CopilotConnection.current
    assert_empty SecurityAuditEvent.where(action: "copilot_connection.connect")
    assert_equal 1, SecurityAuditEvent.where(action: "copilot_connection.disconnect").count
  end

  test "a successful recheck cannot overwrite a replacement saved by another connection" do
    replacement = nil
    outcome = during_successful_check do
      CopilotConnection.disconnect!(actor: @other, browser_session: @other_session)
      replacement = CopilotConnection.connect!(actor: @other, browser_session: @other_session)
    end

    assert_equal :connection_changed, outcome
    assert_equal replacement.attributes, CopilotConnection.current.attributes
    assert_equal [ @other.id ], SecurityAuditEvent.where(action: "copilot_connection.connect").pluck(:user_id)
  end

  test "an initial check cannot restore enablement after a later connect and disconnect" do
    @connection.destroy!
    outcome = during_successful_check do
      CopilotConnection.connect!(actor: @other, browser_session: @other_session)
      CopilotConnection.disconnect!(actor: @other, browser_session: @other_session)
    end

    assert_equal :connection_changed, outcome
    assert_nil CopilotConnection.current
    assert_equal [ @other.id ], SecurityAuditEvent.where(action: "copilot_connection.connect").pluck(:user_id)
  end

  test "an initial check cannot restore enablement after a later connection loses its administrator" do
    @connection.destroy!
    outcome = during_successful_check do
      CopilotConnection.connect!(actor: @other, browser_session: @other_session)
      @other.change_hub_admin!(actor: @admin, browser_session: @session, operation: "revoke")
    end

    assert_equal :connection_changed, outcome
    assert_nil CopilotConnection.current
    assert_not @other.reload.hub_admin?
    assert_equal [ @other.id ], SecurityAuditEvent.where(action: "copilot_connection.connect").pluck(:user_id)
  end

  private

  # A cached request waits outside a transaction while another adapter commits the change.
  def during_successful_check
    reached = Queue.new
    release = Queue.new
    check = CopilotConnection.method(:check!)
    paused = false
    CopilotConnection.define_singleton_method(:check!) do |_token|
      next {} if paused

      paused = true
      checking = ApplicationRecord.connection
      raise "Copilot check held a transaction" if checking.transaction_open?
      raise "Query cache was not enabled" if !checking.query_cache_enabled

      reached << checking.object_id
      Timeout.timeout(10) { release.pop }
      {}
    end
    worker = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        CopilotConnection.cache do
          CopilotConnection.current
          CopilotConnection.connect!(actor: @admin, browser_session: @session)
        end
      end
    rescue CopilotConnection::ChangeDenied => error
      error.reason
    end
    checking_id = Timeout.timeout(10) { reached.pop }
    ApplicationRecord.connection_pool.with_connection do |writing|
      assert_not_equal checking_id, writing.object_id
      yield
    end
    release << true
    Timeout.timeout(10) { worker.value }
  ensure
    release << true if release
    worker&.join
    CopilotConnection.define_singleton_method(:check!, check) if check
    CopilotConnection.private_class_method(:check!)
  end
end
