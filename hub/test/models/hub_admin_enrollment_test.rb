require "test_helper"

class HubAdminEnrollmentTest < ActiveSupport::TestCase
  test "new users are not Hub operators" do
    assert_not users.create.hub_admin?
  end

  test "both the secret and the bound verified identity are required" do
    assert_raises(HubAdminEnrollment::InvalidProof) do
      HubAdminEnrollment.start!("wrong", bootstrap_secret: "expected")
    end
    enrollment, proof = HubAdminEnrollment.start!("expected", bootstrap_secret: "expected")
    enrollment.bind_oauth!("bound-state")
    profile = { "id" => 1002, "login" => "verified-operator" }
    assert_raises(HubAdminEnrollment::InvalidProof) do
      HubAdminEnrollment.consume!(proof:, state: "another-state", profile:)
    end
    assert_empty User.all
    operator = HubAdminEnrollment.consume!(proof:, state: "bound-state", profile:)
    assert_equal 1002, operator.github_id
    assert operator.hub_admin?
    assert_equal operator.id, SecurityAuditEvent.last.user_id
    assert_not_includes enrollment.reload.attributes.to_s, proof
    assert_raises(HubAdminEnrollment::InvalidProof) do
      HubAdminEnrollment.consume!(proof:, state: "bound-state", profile:)
    end
  end

  test "proof expires at the exact deadline and cleanup removes it" do
    enrollment, proof = HubAdminEnrollment.start!("expected", bootstrap_secret: "expected")
    enrollment.bind_oauth!("state")
    travel_to enrollment.expires_at, with_usec: true do
      assert_raises(HubAdminEnrollment::InvalidProof) do
        HubAdminEnrollment.consume!(proof:, state: "state", profile: { "id" => 1001, "login" => "operator" })
      end
      assert_empty User.all
      HubAdminEnrollment.clear_expired!
      assert_not HubAdminEnrollment.exists?(enrollment.id)
    end
  end

  test "audit failure rolls back operator designation and proof consumption" do
    enrollment, proof = HubAdminEnrollment.start!("expected", bootstrap_secret: "expected")
    enrollment.bind_oauth!("state")
    Current.security_audit_context = { cookie: "invalid-context" }
    assert_raises(ActiveRecord::RecordInvalid) do
      HubAdminEnrollment.consume!(proof:, state: "state", profile: { "id" => 1001, "login" => "operator" })
    end
    assert_empty User.all
    assert_nil enrollment.reload.consumed_at
  ensure
    Current.reset
  end
end
