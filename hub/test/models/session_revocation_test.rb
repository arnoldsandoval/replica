require "test_helper"

class SessionRevocationTest < ActiveSupport::TestCase
  setup do
    github_app_configurations.create_installed
    @actor = users.create(hub_admin: true)
    @session = @actor.sessions.create!(fresh_authorized_at: Time.current)
    @other = users.create(github_id: 1002, login: "mona")
    @other_session = @other.sessions.create!
    @repository = repositories.create
  end

  test "ends every authentication class and retains safe actor evidence and public shares" do
    SharingSetting.change!(actor: @actor, browser_session: @session, operation: "enable")
    legacy = grant("legacy", user: @other)
    renewable = grant("renewable", refresh: true)
    expired_access = grant("expired", refresh: true)
    expired_access.update_columns(expires_at: Time.current, created_at: 1.day.ago)
    assert CanvasGrant.authenticate(access_secret("legacy"))
    assert CanvasGrant.for_refresh(refresh_secret("expired"))
    approved, device, refresh = CanvasPairing.start!(@repository, renewable: true)
    approved.approve!(@other, browser_session: @other_session)
    pending, = CanvasPairing.start!(@repository)
    challenge = FreshAuthorization.start!(credential: @session, purpose: "session_revocation")
    enrollment, = HubAdminEnrollment.start!("proof", bootstrap_secret: "proof")
    prototype = prototypes.create(repository: @repository)
    build = builds.create_successful(prototype:)
    handoff = PreviewGrant.issue!(build:, session: @other_session, return_path: "/settings")
    share = ShareLink.create_public! \
      prototype:, build:, created_by: @other, label: "Public", expiration: "seven_days"
    public_handoff = SharePreviewGrant.issue!(share_link: share, return_path: "/")
    generation = SessionRevocation.current.generation
    Current.session = @session
    Current.security_audit_context = {
      source: "browser", ip_address: "127.0.0.1", device_family: "desktop", browser_family: "safari"
    }

    credentials = SessionRevocation.end_all!(actor: @actor, browser_session: @session)

    assert_equal [ @session.id, @other_session.id ].sort, credentials.fetch(:sessions).map(&:id).sort
    assert_empty Session.all
    [ legacy, renewable, expired_access ].each { assert _1.reload.revoked_at }
    %w[legacy renewable expired].each do |name|
      assert_nil CanvasGrant.authenticate(access_secret(name))
      assert_nil CanvasGrant.for_refresh(refresh_secret(name))
    end
    assert_raises(CanvasGrant::Expired) { renewable.renew! }
    assert_raises(CanvasGrant::Expired) { legacy.record_activity! }
    assert_nil CanvasGrant.for_refresh(refresh)
    assert_equal [ "expired", nil ], CanvasPairing.consume(device)
    assert_not CanvasPairing.exists?(approved.id)
    assert_not CanvasPairing.exists?(pending.id)
    assert_not FreshAuthorization.exists?(challenge.id)
    assert_not HubAdminEnrollment.exists?(enrollment.id)
    assert_nil PreviewGrant.find_valid(handoff, build_id: build.id)
    assert ShareLink.exists?(share.id)
    assert SharePreviewGrant.find_valid(public_handoff, build_id: build.id)
    assert_equal generation + 1, SessionRevocation.current.generation
    event = SecurityAuditEvent.global.where(action: "session_revocation.end_all").sole
    assert_equal "succeeded", event.outcome
    assert_equal @actor.id, event.user_id
    assert_equal @session.id, event.context.fetch("session_id")
    assert_equal "desktop", event.context.fetch("device_family")
    assert_equal "127.0.0.1", event.ip_address
    assert_not event.repository_scoped?
    assert @actor.reload.hub_admin?
    assert Repository.exists?(@repository.id)
    assert Build.exists?(build.id)
  end

  test "a stale role or deleted same-browser Session cannot revoke credentials" do
    @actor.update!(hub_admin: false)
    assert_no_difference("Session.count") do
      assert_raises(User::AdminRoleChangeDenied) do
        SessionRevocation.end_all!(actor: @actor, browser_session: @session)
      end
    end
    @actor.update!(hub_admin: true)
    @session.destroy!
    assert_no_difference("Session.count") do
      assert_raises(User::AdminRoleChangeDenied) do
        SessionRevocation.end_all!(actor: @actor, browser_session: @session)
      end
    end
    assert_empty SecurityAuditEvent.where(action: "session_revocation.end_all")
  end

  test "another browser's fresh proof cannot authorize this Session" do
    @actor.sessions.create!(fresh_authorized_at: Time.current)
    @session.update!(fresh_authorized_at: 5.minutes.ago)
    assert_no_difference("Session.count") do
      assert_raises(FreshAuthorization::Invalid) do
        SessionRevocation.end_all!(actor: @actor, browser_session: @session)
      end
    end
  end

  test "a failed success audit rolls back the cutoff and every credential change" do
    connection = grant("rollback", refresh: true)
    cutoff = SessionRevocation.current
    previous = SecurityAuditEvent.method(:record!)
    SecurityAuditEvent.define_singleton_method(:record!) do |**|
      raise ActiveRecord::RecordInvalid, SecurityAuditEvent.new
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      SessionRevocation.end_all!(actor: @actor, browser_session: @session)
    end
    assert Session.exists?(@session.id)
    assert Session.exists?(@other_session.id)
    assert_nil connection.reload.revoked_at
    assert_equal 0, cutoff.reload.generation
  ensure
    SecurityAuditEvent.define_singleton_method(:record!, previous) if previous
  end

  test "old OAuth generation cannot issue a Session but a new sign-in can" do
    generation = SessionRevocation.current.generation
    SessionRevocation.end_all!(actor: @actor, browser_session: @session)
    assert_raises(SessionRevocation::Superseded) do
      SessionRevocation.with_generation!(generation) { @other.sessions.create! }
    end
    SessionRevocation.with_generation!(SessionRevocation.current.generation) { @other.sessions.create! }
    assert_equal 1, @other.sessions.count
  end

  test "missing or malformed captured generations cannot issue credentials" do
    [ nil, "0", -1, {}, 0.0 ].each do |generation|
      assert_no_difference("Session.count") do
        assert_raises(SessionRevocation::Superseded) do
          SessionRevocation.with_generation!(generation) { @other.sessions.create! }
        end
      end
    end
  end

  test "disconnect commands name only ended credential IDs and disable reconnection" do
    connection = grant("disconnect")
    credentials = { sessions: [ @session, @other_session ], canvas_grants: [ connection ] }
    remote = ActionCable.server.remote_connections
    previous = remote.method(:where)
    requested = []
    remote.define_singleton_method(:where) do |**identifiers|
      Object.new.tap do |connection|
        connection.define_singleton_method(:disconnect) do |reconnect:|
          requested << [ identifiers, reconnect ]
        end
      end
    end
    SessionRevocation.disconnect!(credentials)
    assert_equal [
      [ { current_user: @actor, credential_identity: @session.to_gid_param }, false ],
      [ { current_user: @other, credential_identity: @other_session.to_gid_param }, false ],
      [ { current_user: @actor, credential_identity: connection.to_gid_param }, false ]
    ], requested
  ensure
    remote&.define_singleton_method(:where, previous) if previous
  end

  test "one failed transport delivery does not prevent the other disconnect attempts" do
    credentials = { sessions: [ @session, @other_session ], canvas_grants: [] }
    remote = ActionCable.server.remote_connections
    previous = remote.method(:where)
    attempted = []
    first_identity = @session.to_gid_param
    remote.define_singleton_method(:where) do |**identifiers|
      Object.new.tap do |connection|
        connection.define_singleton_method(:disconnect) do |reconnect:|
          attempted << identifiers.fetch(:credential_identity)
          raise IOError if identifiers.fetch(:credential_identity) == first_identity
        end
      end
    end
    assert_raises(IOError) { SessionRevocation.disconnect!(credentials) }
    assert_equal [ @session.to_gid_param, @other_session.to_gid_param ], attempted
  ensure
    remote&.define_singleton_method(:where, previous) if previous
  end

  private

  def grant(name, user: @actor, refresh: false)
    CanvasGrant.create! \
      user:, repository: @repository, token_digest: Digest::SHA256.hexdigest(access_secret(name)),
      expires_at: 7.days.from_now,
      refresh_token_digest: refresh ? Digest::SHA256.hexdigest(refresh_secret(name)) : nil,
      last_active_at: refresh ? Time.current : nil,
      inactive_at: refresh ? 30.days.from_now : nil
  end

  def access_secret(name)
    "rp_#{Digest::SHA256.hexdigest(name).first(43)}"
  end

  def refresh_secret(name)
    "rr_#{Digest::SHA256.hexdigest(name).first(43)}"
  end
end
