require "test_helper"

class FreshAuthorizationTest < ActiveSupport::TestCase
  setup do
    @user = users.create
    @session = @user.sessions.create!
    @grant = CanvasGrant.create! \
      user: @user, repository: repositories.create,
      token_digest: Digest::SHA256.hexdigest("access"), expires_at: 7.days.from_now
    @profile = { "id" => @user.github_id, "login" => @user.login }
  end

  test "authorization expires at exactly five minutes and rejects future timestamps" do
    travel_to Time.current.change(usec: 0) do
      [ @session, @grant ].each do |credential|
        assert_not FreshAuthorization.fresh?(credential)
        credential.update!(fresh_authorized_at: Time.current)
        assert FreshAuthorization.fresh?(credential)
        credential.update!(fresh_authorized_at: Time.current - 5.minutes + 1.second)
        assert FreshAuthorization.fresh?(credential)
        credential.update!(fresh_authorized_at: 5.minutes.ago)
        assert_not FreshAuthorization.fresh?(credential)
        credential.update!(fresh_authorized_at: 1.second.from_now)
        assert_not FreshAuthorization.fresh?(credential)
      end
    end
  end

  test "only the credential whose GitHub identity was verified becomes fresh" do
    another_session = @user.sessions.create!
    another_grant = @grant.dup
    another_grant.token_digest = Digest::SHA256.hexdigest("another")
    another_grant.save!
    [ @session, @grant ].each do |credential|
      challenge = claim(credential)
      challenge.verify!(@profile)
      assert FreshAuthorization.fresh?(credential)
      assert_not FreshAuthorization.fresh?(another_session)
      assert_not FreshAuthorization.fresh?(another_grant)
      assert_raises(FreshAuthorization::Invalid) { challenge.verify!(@profile) }
    end
  end

  test "callbacks are one use and reject wrong state or browser scope" do
    challenge = FreshAuthorization.start!(credential: @session, purpose: "analytics_destination")
    challenge.bind_oauth!("state", browser_session: @session)
    assert_raises(FreshAuthorization::Invalid) do
      challenge.claim!(state: "wrong", browser_session: @session)
    end
    assert_raises(FreshAuthorization::Invalid) do
      challenge.claim!(state: "state", browser_session: @user.sessions.create!)
    end
    challenge.claim!(state: "state", browser_session: @session)
    competing_callback = FreshAuthorization.find(challenge.id)
    assert_raises(FreshAuthorization::Invalid) do
      competing_callback.claim!(state: "state", browser_session: @session)
    end
    assert_not FreshAuthorization.fresh?(@session)
  end

  test "concurrent callbacks can verify a challenge only once" do
    challenge = FreshAuthorization.start!(credential: @session, purpose: "analytics_destination")
    challenge.bind_oauth!("state", browser_session: @session)
    ready = Queue.new
    start = Queue.new
    callbacks = 2.times.map do
      Thread.new do
        ready << true
        start.pop
        ActiveRecord::Base.connection_pool.with_connection do
          callback = FreshAuthorization.find(challenge.id)
          callback.claim!(state: "state", browser_session: @session)
          callback.verify!(@profile)
          :verified
        rescue FreshAuthorization::Invalid
          :denied
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }

    assert_equal [ :denied, :verified ], callbacks.map(&:value).sort
    assert FreshAuthorization.fresh?(@session)
    assert_equal 1, SecurityAuditEvent.where(action: "fresh_authorization.verify", outcome: "succeeded").count
  end

  test "a different or malformed GitHub identity never renews the credential" do
    [ { "id" => @user.github_id + 1, "login" => "other" }, { "id" => @user.github_id.to_s },
      nil, {} ].each do |profile|
      challenge = claim(@session)
      assert_raises(FreshAuthorization::Invalid) { challenge.verify!(profile) }
      assert_not FreshAuthorization.fresh?(@session)
    end
  end

  test "deleted sessions and revoked or expired grants cannot be revived at callback" do
    session_challenge = claim(@session)
    @session.destroy!
    assert_raises(FreshAuthorization::Invalid) { session_challenge.verify!(@profile) }
    canvas_challenge = claim(@grant)
    @grant.update!(revoked_at: Time.current)
    assert_raises(FreshAuthorization::Invalid) { canvas_challenge.verify!(@profile) }
    @grant.update!(revoked_at: nil)
    expired_challenge = claim(@grant)
    @grant.update_columns(expires_at: Time.current, created_at: 1.day.ago)
    assert_raises(FreshAuthorization::Invalid) { expired_challenge.verify!(@profile) }
    assert_nil @grant.reload.fresh_authorized_at
  end

  test "challenge expiration and cancellation do not authorize a mutation" do
    challenge = claim(@session)
    travel_to challenge.expires_at, with_usec: true do
      assert_raises(FreshAuthorization::Invalid) { challenge.verify!(@profile) }
    end
    cancelled = FreshAuthorization.start!(credential: @session, purpose: "analytics_destination")
    cancelled.cancel!(browser_session: @session)
    assert_raises(FreshAuthorization::Invalid) { cancelled.bind_oauth!("state", browser_session: @session) }
    assert_not FreshAuthorization.fresh?(@session)
  end

  test "expiry at the credential lock cannot renew a browser or canvas proof" do
    [ @session, @grant ].each do |credential|
      challenge = claim(credential)
      challenge.define_singleton_method(:credential) { credential }
      expire = -> { travel_to challenge.expires_at, with_usec: true }
      original_lock = credential.method(:with_lock)
      credential.define_singleton_method(:with_lock) do |&block|
        original_lock.call do
          expire.call
          block.call
        end
      end

      assert_no_difference("SecurityAuditEvent.where(action: 'fresh_authorization.verify').count") do
        assert_raises(FreshAuthorization::Invalid) { challenge.verify!(@profile) }
      end
      assert_nil credential.reload.fresh_authorized_at
      assert_nil challenge.reload.verified_at
      travel_back
    end
  ensure
    travel_back
  end

  test "the credential and challenge retain the same checked verification time" do
    [ @session, @grant ].each do |credential|
      challenge = claim(credential)
      challenge.define_singleton_method(:credential) { credential }
      now = Time.current.change(usec: 0) + 1.second
      travel_to now
      advance = -> { travel_to now + 1.second }
      original_update = credential.method(:update!)
      credential.define_singleton_method(:update!) do |**attributes|
        original_update.call(**attributes).tap { advance.call }
      end

      challenge.verify!(@profile)
      assert_equal now, credential.reload.fresh_authorized_at
      assert_equal now, challenge.reload.verified_at
      travel_back
    end
  ensure
    travel_back
  end

  test "canvas callbacks retain the initiating grant context without unlocking their browser" do
    Current.session = @session
    challenge = claim(@grant)
    challenge.verify!(@profile)
    event = SecurityAuditEvent.where(action: "fresh_authorization.verify").last
    assert_equal @user.id, event.user_id
    assert_equal @grant.repository, event.repository
    assert_equal "canvas", event.context.fetch("source")
    assert_equal @grant.id, event.context.fetch("canvas_grant_id")
    assert_not event.context.key?("session_id")
    assert_not FreshAuthorization.fresh?(@session)
  end

  test "new database records and token renewal do not establish fresh GitHub identity" do
    @user.update!(last_authenticated_at: Time.current)
    assert_not FreshAuthorization.fresh?(@session)
    assert_not FreshAuthorization.fresh?(@grant)
    @grant.update! \
      refresh_token_digest: Digest::SHA256.hexdigest("refresh"),
      last_active_at: Time.current, inactive_at: 30.days.from_now
    @grant.renew!
    @grant.record_activity!
    assert_not FreshAuthorization.fresh?(@grant)
  end

  test "purpose and return path are bounded and cannot carry an external redirect" do
    assert_raises(ActiveRecord::RecordInvalid) do
      FreshAuthorization.start!(credential: @session, purpose: "unapproved")
    end
    [ "https://elsewhere.example", "//elsewhere.example", "/\\elsewhere.example", "/\nelsewhere" ].each do |path|
      assert_raises(ActiveRecord::RecordInvalid) do
        FreshAuthorization.start!(credential: @session, purpose: "analytics_destination", return_to: path)
      end
    end
  end

  test "administrator challenges require a live GitHub-backed browser administrator" do
    FreshAuthorization::ADMIN_PURPOSES.each do |purpose|
      @user.update!(hub_admin: false)
      assert_raises(FreshAuthorization::Invalid) do
        FreshAuthorization.start!(credential: @session, purpose:)
      end
      @user.update!(hub_admin: true)
      assert_raises(FreshAuthorization::Invalid) do
        FreshAuthorization.start!(credential: @grant, purpose:)
      end
      challenge = FreshAuthorization.start!(credential: @session, purpose:)
      assert challenge.available_to?(@session)
      @user.update!(hub_admin: false)
      assert_not challenge.available_to?(@session)
      assert_raises(FreshAuthorization::Invalid) do
        challenge.bind_oauth!("state", browser_session: @session)
      end
    end
  end

  test "losing an administrator role before claim or verification cannot renew proof" do
    @user.update!(hub_admin: true)
    challenge = FreshAuthorization.start!(credential: @session, purpose: "hub_admin_management")
    challenge.bind_oauth!("state", browser_session: @session)
    @user.update!(hub_admin: false)
    assert_raises(FreshAuthorization::Invalid) do
      challenge.claim!(state: "state", browser_session: @session)
    end
    assert_nil challenge.reload.consumed_at

    @user.update!(hub_admin: true)
    challenge.claim!(state: "state", browser_session: @session)
    @user.update!(hub_admin: false)
    assert_raises(FreshAuthorization::Invalid) { challenge.verify!(@profile) }
    assert_nil challenge.reload.verified_at
    assert_not FreshAuthorization.fresh?(@session)
  end

  test "changing the persisted GitHub identity cannot renew an earlier challenge" do
    challenge = claim(@session)
    @user.update_columns(github_id: @user.github_id + 1)
    assert_raises(FreshAuthorization::Invalid) { challenge.verify!(@profile) }
    assert_not FreshAuthorization.fresh?(@session)
    assert_nil challenge.reload.verified_at
  end

  private

  def claim(credential)
    challenge = FreshAuthorization.start!(credential:, purpose: "analytics_destination")
    challenge.bind_oauth!("state", browser_session: @session)
    challenge.claim!(state: "state", browser_session: @session)
    challenge
  end
end
