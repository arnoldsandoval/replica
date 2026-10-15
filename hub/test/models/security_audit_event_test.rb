require "test_helper"

class SecurityAuditEventTest < ActiveSupport::TestCase
  test "records an anonymous command separately from analytics" do
    assert_no_difference("Analytics::Event.count") do
      event = SecurityAuditEvent.record!(action: "github_app.reset", outcome: "denied", actor: nil)
      assert_nil event.user_id
      assert_nil event.repository_id
      assert_nil event.ip_address
      assert_equal({ "source" => "command" }, event.context)
    end
  end

  test "rejects secret context arbitrary text and malformed IP addresses" do
    [
      { access_token: "never-store-me" }, { headers: { cookie: "private" } },
      { device_family: "secret-in-a-device-name" }, { canvas_grant_id: "credential" }
    ].each do |context|
      assert_raises(ActiveRecord::RecordInvalid) do
        SecurityAuditEvent.record!(action: "canvas_connection.renew", outcome: "failed", context:)
      end
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      SecurityAuditEvent.record!(action: "github_app.reset", outcome: "denied",
        context: { ip_address: "arbitrary header data" })
    end
    assert_empty SecurityAuditEvent.all
  end

  test "device snapshots contain only fixed nonsecret categories" do
    context = SecurityAuditEvent.device_context("Macintosh Chrome/123 credential-never-retain-this")
    assert_equal({ device_family: "desktop", browser_family: "chrome" }, context)
    event = SecurityAuditEvent.record!(action: "hub_admin.enroll", outcome: "succeeded", context:)
    assert_not_includes event.attributes.to_s, "credential-never-retain-this"
  end

  test "role targets remain distinct from actors and accept only positive identifiers" do
    actor = users.create
    target = users.create(github_id: 1002, login: "mona")
    event = SecurityAuditEvent.record! \
      action: "hub_admin.designate", outcome: "succeeded", actor:,
      context: { target_user_id: target.id }
    target.destroy!
    assert_equal actor.id, event.user_id
    assert_equal target.id, event.reload.context.fetch("target_user_id")
    [ 0, -1, "1002", { github_id: 1002 } ].each do |id|
      assert_raises(ActiveRecord::RecordInvalid) do
        SecurityAuditEvent.record! \
          action: "hub_admin.designate", outcome: "denied", context: { target_user_id: id }
      end
    end
  end

  test "deleted repositories do not turn retained records into deployment records" do
    repository = repositories.create
    event = SecurityAuditEvent.record!(action: "share_link.delete", outcome: "succeeded", repository:)
    repository.destroy!

    assert_nil event.reload.repository_id
    assert event.repository_scoped?
    assert SecurityAuditEvent.retained.exists?(event.id)
    assert_not SecurityAuditEvent.global.exists?(event.id)
  end

  test "deleting an actor retains the audit without changing its scope" do
    actor = users.create
    repository = repositories.create
    event = SecurityAuditEvent.record!(action: "security_audit.view", outcome: "succeeded",
      repository:, actor:)
    actor.destroy!

    assert_nil event.reload.user_id
    assert_equal repository.id, event.repository_id
    assert event.repository_scoped?
    assert_not SecurityAuditEvent.global.exists?(event.id)
  end

  test "state changes roll back when their audit cannot be recorded" do
    SharingSetting.create!(id: 1, public_sharing_enabled: true)
    prototype = prototypes.create
    build = builds.create_successful(prototype:)
    actor = users.create
    Current.security_audit_context = { raw_payload: "not allowed" }
    assert_no_difference("ShareLink.count") do
      assert_raises(ActiveRecord::RecordInvalid) do
        ShareLink.create_public!(prototype:, build:, created_by: actor, label: "Example")
      end
    end
  ensure
    Current.reset
  end

  test "facts remain immutable and expire only after ninety days" do
    travel_to Time.current.change(usec: 0) do
      expired = SecurityAuditEvent.record!(action: "github_app.reset", outcome: "denied",
        occurred_at: 90.days.ago - 1.second)
      retained = SecurityAuditEvent.record!(action: "github_app.reset", outcome: "denied",
        occurred_at: 90.days.ago)
      assert_raises(ActiveRecord::ReadOnlyRecord) { retained.update!(outcome: "succeeded") }
      assert_raises(ActiveRecord::ReadOnlyRecord) { retained.destroy! }
      assert_equal [ retained.id ], SecurityAuditEvent.retained.pluck(:id)
      SecurityAuditEvent.clear_expired!
      assert_not SecurityAuditEvent.exists?(expired.id)
      assert SecurityAuditEvent.exists?(retained.id)
    end
  end
end
