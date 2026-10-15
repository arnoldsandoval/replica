require "test_helper"
require_relative "../support/share_link_lifetime_helpers"

class SharingSettingTest < ActiveSupport::TestCase
  include ShareLinkLifetimeHelpers
  setup do
    seed "repositories/github_prototype"
    @actor = users.octocat
    @actor.update!(hub_admin: true)
    @session = @actor.sessions.create!(fresh_authorized_at: Time.current)
  end

  test "missing and default persisted settings deny direct model creation" do
    assert_not SharingSetting.enabled?
    assert_raises(SharingSetting::Disabled) { create_link }
    assert_empty ShareLink.all
    SharingSetting.create!(id: 1)
    assert_not SharingSetting.enabled?
    assert_raises(SharingSetting::Disabled) { create_link }
  end

  test "disable permanently revokes every link and grant while enabling permits new links only" do
    change("enable")
    link = create_link
    token = SharePreviewGrant.issue!(share_link: link)
    grant = SharePreviewGrant.find_valid(token, build_id: link.build_id)
    change("disable")
    assert_not SharePreviewGrant.consume(grant)
    assert_raises(SharingSetting::Disabled) { SharePreviewGrant.issue!(share_link: link) }
    assert link.reload.revoked_at
    assert_empty SharePreviewGrant.all
    assert_not link.available?
    change("enable")
    assert_not link.reload.available?
    assert_nil SharePreviewGrant.find_valid(token, build_id: link.build_id)
    assert create_link.available?
    assert_not link.update(revoked_at: nil)
    assert_equal 1, ShareLink.active.count
  end

  test "an earlier policy revision cannot create after disabling and re enabling" do
    change("enable")
    revision = SharingSetting.revision
    change("disable")
    change("enable")
    assert_raises(SharingSetting::Changed) { create_link(sharing_revision: revision) }
    assert_empty ShareLink.all
  end

  test "disable revokes legacy never and long lived links before a policy backfill" do
    change("enable")
    links = with_share_link_maximum_lifetime(nil) do
      %w[never thirty_days].map { |expiration| create_link(expiration:) }
    end
    links.each { |link| SharePreviewGrant.issue!(share_link: link) }
    with_share_link_maximum_lifetime(7.days) do
      change("disable")
      assert_not SharingSetting.enabled?
      assert_empty SharePreviewGrant.all
      links.each do |link|
        assert link.reload.revoked_at
        assert_not link.available?
      end
      change("enable")
      links.each { |link| assert_not link.reload.available? }
    end
  end

  test "role Session and freshness are reread before changing state" do
    @actor.update!(hub_admin: false)
    assert_raises(SharingSetting::ChangeDenied) { change("enable") }
    @actor.update!(hub_admin: true)
    @session.update!(fresh_authorized_at: 5.minutes.ago)
    assert_raises(FreshAuthorization::Invalid) { change("enable") }
    @session.destroy!
    assert_raises(SharingSetting::ChangeDenied) { change("enable") }
    assert_not SharingSetting.enabled?
  end

  test "failed audit rolls back policy links and handoffs atomically" do
    change("enable")
    link = create_link
    SharePreviewGrant.issue!(share_link: link)
    Current.security_audit_context = { payload: "not allowed" }
    assert_raises(ActiveRecord::RecordInvalid) { change("disable") }
    assert SharingSetting.enabled?
    assert_nil link.reload.revoked_at
    assert_equal 1, SharePreviewGrant.count
  ensure
    Current.reset
  end

  test "an in flight stream stops at its next chunk after disable even if re enabled" do
    change("enable")
    link = create_link
    body = Object.new
    closed = false
    body.define_singleton_method(:each) do |&block|
      block.call("already delivered")
      block.call("not delivered")
    end
    body.define_singleton_method(:close) { closed = true }
    sent = []
    PublicShareResponseBody.new(body, link.id).each do |chunk|
      sent << chunk
      change("disable")
      change("enable")
    end
    assert_equal [ "already delivered" ], sent
    assert closed
  end

  private

  def change(operation)
    SharingSetting.change!(actor: @actor, browser_session: @session, operation:)
  end

  def create_link(**extra)
    ShareLink.create_public! \
      prototype: prototypes.welcome, build: builds.welcome, created_by: @actor, label: "Review",
      **extra
  end
end
