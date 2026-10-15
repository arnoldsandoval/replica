require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  include ActionCable::TestHelper

  test "connects through a live Hub session" do
    user = users.create
    browser_session = user.sessions.create!

    connect session: { authenticated_session_id: browser_session.id }

    assert_equal user, connection.current_user
    assert_equal browser_session.id, connection.browser_session_id
    assert connection.credential_active?
  end

  test "a connected browser loses authorization when its persisted Session ends" do
    user = users.create(hub_admin: true)
    browser_session = user.sessions.create!(fresh_authorized_at: Time.current)
    connect session: { authenticated_session_id: browser_session.id }
    assert connection.credential_active?
    credentials = SessionRevocation.end_all!(actor: user, browser_session:)
    assert_broadcast_on connection.send(:internal_channel), { type: "disconnect", reconnect: false } do
      SessionRevocation.disconnect!(credentials)
    end
    assert_not connection.credential_active?
    assert_reject_connection { connect session: { authenticated_session_id: browser_session.id } }
  end

  test "a browser and canvas with the same numeric ID have distinct disconnect identities" do
    user = users.create
    browser = user.sessions.create!
    grant = CanvasGrant.create! \
      id: browser.id, user:, repository: repositories.create,
      token_digest: Digest::SHA256.hexdigest("distinct-identity"), expires_at: 7.days.from_now
    assert_not_equal browser.to_gid_param, grant.to_gid_param
    connect session: { authenticated_session_id: browser.id }
    assert_equal browser.to_gid_param, connection.credential_identity
  end

  test "rejects a missing or revoked Hub session" do
    assert_reject_connection { connect }

    browser_session = users.create.sessions.create!
    browser_session.destroy!

    assert_reject_connection do
      connect session: { authenticated_session_id: browser_session.id }
    end
  end

  test "rejects a GitHub session in local mode" do
    browser_session = users.create.sessions.create!

    with_local_mode do
      assert_reject_connection do
        connect session: { authenticated_session_id: browser_session.id }
      end
    end
  end

  test "rejects a local session in GitHub mode" do
    browser_session = with_local_mode { User.local_developer!.sessions.create! }

    assert_reject_connection do
      connect session: { authenticated_session_id: browser_session.id }
    end
  end

  test "accepts an originless paired extension only while its ticket and grant are valid" do
    github_app_configurations.create_installed
    stub_github_installation_token
    user = users.create
    repository = repositories.create
    stub_github_permissions \
      [ {
        "id" => repository.github_id,
        "full_name" => repository.name_with_owner,
        "default_branch" => repository.default_branch
      } ],
      { repository.github_id => "pull" }
    grant = CanvasGrant.create! \
      user:,
      repository:,
      token_digest: Digest::SHA256.hexdigest("ticket-test"),
      expires_at: 7.days.from_now
    signed = Rails.application.message_verifier("canvas-cable").generate \
      grant.id,
      purpose: "canvas-cable",
      expires_in: 30.seconds
    ticket = Base64.urlsafe_encode64(signed, padding: false)
    headers = { "Sec-WebSocket-Protocol" => "actioncable-v1-json, replica-canvas.#{ticket}" }

    connect headers: headers
    assert_equal user, connection.current_user
    assert_equal grant.id, connection.canvas_grant_id
    assert connection.send(:allow_request_origin?)

    grant.update!(revoked_at: Time.current)
    assert_not connection.credential_active?
    assert_reject_connection { connect headers: headers }
    grant.update!(revoked_at: nil)

    travel 31.seconds do
      assert_reject_connection { connect headers: headers }
    end
  end

  private

  def with_local_mode
    original = LocalDevelopment.method(:enabled?)
    LocalDevelopment.define_singleton_method(:enabled?) { true }
    yield
  ensure
    LocalDevelopment.define_singleton_method(:enabled?, original)
  end
end
