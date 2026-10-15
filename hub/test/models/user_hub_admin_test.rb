require "test_helper"

class UserHubAdminTest < ActiveSupport::TestCase
  setup do
    @actor = users.create(hub_admin: true)
    @target = users.create(github_id: 1002, login: "mona")
    @session = @actor.sessions.create!(fresh_authorized_at: Time.current)
  end

  test "designation and removal record distinct actor and target facts" do
    change("designate")
    assert @target.reload.hub_admin?
    event = SecurityAuditEvent.last
    assert_equal @actor.id, event.user_id
    assert_equal @target.id, event.context.fetch("target_user_id")
    assert_equal @session.id, event.context.fetch("session_id")
    assert_equal "hub_admin.designate", event.action
    assert_not event.repository_scoped?
    change("revoke")
    assert_not @target.reload.hub_admin?
    assert_equal "hub_admin.revoke", SecurityAuditEvent.last.action
  end

  test "a stale actor cannot designate or remove after losing the role" do
    @target.update!(hub_admin: true)
    User.find(@actor.id).update!(hub_admin: false)
    assert @actor.hub_admin?
    assert_no_difference("SecurityAuditEvent.count") do
      error = assert_raises(User::AdminRoleChangeDenied) { change("revoke") }
      assert_equal :not_authorized, error.reason
    end
    assert @target.reload.hub_admin?
    @target.update!(hub_admin: false)
    assert_raises(User::AdminRoleChangeDenied) { change("designate") }
    assert_not @target.reload.hub_admin?
  end

  test "the final administrator cannot remove their own role" do
    error = assert_raises(User::AdminRoleChangeDenied) do
      @actor.change_hub_admin!(actor: @actor, browser_session: @session, operation: "revoke")
    end
    assert_equal :last_admin, error.reason
    assert @actor.reload.hub_admin?
    assert_empty SecurityAuditEvent.all
  end

  test "stale confirmation cannot invert an already changed role" do
    change("designate")
    error = assert_raises(User::AdminRoleChangeDenied) { change("designate") }
    assert_equal :role_changed, error.reason
    assert @target.reload.hub_admin?
    assert_equal 1, SecurityAuditEvent.count
  end

  test "a different expired or deleted Session cannot authorize a role change" do
    other = @target.sessions.create!(fresh_authorized_at: Time.current)
    assert_raises(User::AdminRoleChangeDenied) do
      @target.change_hub_admin!(actor: @actor, browser_session: other, operation: "designate")
    end
    @session.update!(fresh_authorized_at: 5.minutes.ago)
    assert_raises(FreshAuthorization::Invalid) { change("designate") }
    @session.destroy!
    assert_raises(User::AdminRoleChangeDenied) { change("designate") }
    assert_not @target.reload.hub_admin?
  end

  test "deleted actors and targets cannot be reused through stale objects" do
    @target.destroy!
    assert_raises(ActiveRecord::RecordNotFound) { change("designate") }
    @actor.destroy!
    assert_raises(User::AdminRoleChangeDenied) { change("designate") }
  end

  test "local identities and unknown operations cannot gain a role" do
    @target.update_columns(github_id: nil)
    assert_raises(User::AdminRoleChangeDenied) { change("designate") }
    @target.update_columns(github_id: 1002)
    error = assert_raises(User::AdminRoleChangeDenied) { change("anything") }
    assert_equal :invalid_operation, error.reason
    assert_not @target.reload.hub_admin?
  end

  test "audit failure rolls back the role change" do
    Current.security_audit_context = { raw_payload: "not allowed" }
    assert_raises(ActiveRecord::RecordInvalid) { change("designate") }
    assert_not @target.reload.hub_admin?
  ensure
    Current.reset
  end

  test "bulk designation commits all roles with one audit per target" do
    other = users.create(github_id: 1003, login: "other")
    designate(@target, other)
    assert @target.reload.hub_admin?
    assert other.reload.hub_admin?
    assert_equal [ @target.id, other.id ], SecurityAuditEvent.all.map { _1.context.fetch("target_user_id") }
  end

  test "an already changed target rolls back earlier roles and their audits" do
    other = users.create(github_id: 1003, login: "other", hub_admin: true)
    assert_no_difference("SecurityAuditEvent.count") do
      error = assert_raises(User::AdminRoleChangeDenied) { designate(@target, other) }
      assert_equal :role_changed, error.reason
    end
    assert_not @target.reload.hub_admin?
  end

  test "missing or local targets cannot partially designate a selection" do
    other = users.create(github_id: 1003, login: "other")
    other.update_columns(github_id: nil)
    assert_raises(User::AdminRoleChangeDenied) { designate(@target, other) }
    assert_not @target.reload.hub_admin?
    other.destroy!
    assert_raises(User::AdminRoleChangeDenied) { designate(@target, other) }
    assert_not @target.reload.hub_admin?
    assert_empty SecurityAuditEvent.all
  end

  test "bulk designation rejects stale actors and expired deleted or foreign Sessions" do
    @session.update!(fresh_authorized_at: 5.minutes.ago)
    assert_raises(FreshAuthorization::Invalid) { designate(@target) }
    @session.update!(fresh_authorized_at: Time.current)
    User.find(@actor.id).update!(hub_admin: false)
    assert_raises(User::AdminRoleChangeDenied) { designate(@target) }
    @actor.reload.update!(hub_admin: true)
    assert @actor.reload.hub_admin?
    foreign = @target.sessions.create!(fresh_authorized_at: Time.current)
    assert_raises(User::AdminRoleChangeDenied) do
      User.designate_hub_admins!(actor: @actor, browser_session: foreign, user_ids: [ @target.id.to_s ])
    end
    @session.destroy!
    assert @actor.reload.hub_admin?
    assert_raises(User::AdminRoleChangeDenied) { designate(@target) }
    assert_not @target.reload.hub_admin?
    assert_empty SecurityAuditEvent.all
  end

  test "bulk designation rejects empty malformed duplicate and oversized selections" do
    [ nil, [], "1", [ 1 ], [ "0" ], [ "1x" ], [ "1", "1" ], Array.new(51, "1") ].each do |ids|
      error = assert_raises(User::AdminRoleChangeDenied) do
        User.designate_hub_admins!(actor: @actor, browser_session: @session, user_ids: ids)
      end
      assert_equal :invalid_selection, error.reason
    end
    assert_not @target.reload.hub_admin?
  end

  test "a later save failure rolls back the full selection and audits" do
    other = users.create(github_id: 1003, login: "other")
    validation = ->(user) { user.errors.add(:base, "Could not save") if user.id == other.id }
    User.validate(validation)
    assert_raises(ActiveRecord::RecordInvalid) { designate(@target, other) }
    assert_not @target.reload.hub_admin?
    assert_not other.reload.hub_admin?
    assert_empty SecurityAuditEvent.all
  ensure
    User.skip_callback(:validate, :before, validation) if validation
  end

  test "bulk audit failure rolls back all role changes" do
    Current.security_audit_context = { raw_payload: "not allowed" }
    assert_raises(ActiveRecord::RecordInvalid) { designate(@target) }
    assert_not @target.reload.hub_admin?
  ensure
    Current.reset
  end

  private

  def designate(*targets)
    User.designate_hub_admins! \
      actor: @actor, browser_session: @session, user_ids: targets.map { _1.id.to_s }
  end

  def change(operation)
    @target.change_hub_admin!(actor: @actor, browser_session: @session, operation:)
  end
end
