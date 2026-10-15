require "test_helper"
require "timeout"

# Committed adapters expose writer progress and secret retirement during hashing.
class GithubWebhookSignatureConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @configuration = github_app_configurations.create_installed \
      previous_webhook_secret: "previous-webhook-secret", webhook_rotation_state: "confirmed"
    @actor = users.create(github_id: 9931, login: "webhook-admin", hub_admin: true)
    @session = sessions.create(user: @actor, fresh_authorized_at: Time.current)
  end

  teardown do
    SecurityAuditEvent.where(user_id: @actor.id)
      .or(SecurityAuditEvent.where("json_extract(context, '$.github_app_configuration_id') = ?", @configuration.id))
      .delete_all
    Session.where(user_id: @actor.id).delete_all
    User.where(id: @actor.id).delete_all
    GithubAppConfiguration.where(id: @configuration.id).delete_all
    SessionRevocation.delete_all
  end

  test "an invalid signature on a maximum size body does not block other writers" do
    body = JSON.generate(action: "opened").ljust(GithubWebhook::MAXIMUM_BODY_SIZE, " ")
    outcome = during_hash(body:, signature: "sha256=#{"0" * 64}") do
      @actor.update!(name: "Writer completed during hashing")
    end

    assert_equal GithubWebhook::Rejected, outcome
    assert_equal "Writer completed during hashing", @actor.reload.name
    assert_empty WebhookDelivery.all
  end

  test "a previous secret retired during cached hashing cannot authenticate a delivery" do
    body = JSON.generate(action: "opened")
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @configuration.previous_webhook_secret, body)}"
    revision = @configuration.credential_revision
    outcome = during_hash(body:, signature:) do
      @configuration.administration.finish_webhook! \
        actor: @actor, browser_session: @session, expected_version: @configuration.lock_version
      assert_equal revision, @configuration.reload.credential_revision
      assert_nil @configuration.previous_webhook_secret
    end

    assert_equal GithubWebhook::Rejected, outcome
    assert_empty WebhookDelivery.all
    assert_equal 1, SecurityAuditEvent.where(action: "github_app.finish_webhook_rotation").count
  end

  private

  # A paused first hash permits a separate committed writer before authentication ends.
  def during_hash(body:, signature:)
    reached = Queue.new
    release = Queue.new
    original = OpenSSL::HMAC.method(:hexdigest)
    paused = false
    OpenSSL::HMAC.define_singleton_method(:hexdigest) do |digest, secret, data|
      if data == body && !paused
        paused = true
        connection = ApplicationRecord.connection
        reached << { connection_id: connection.object_id, transaction_open: connection.transaction_open? }
        Timeout.timeout(10) { release.pop }
      end
      original.call(digest, secret, data)
    end
    worker = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        GithubAppConfiguration.cache do
          assert ApplicationRecord.connection.query_cache_enabled
          configuration = GithubAppConfiguration.find(@configuration.id)
          GithubWebhook.process! \
            configuration:, body:, signature:, delivery_id: SecureRandom.uuid, event: "issues"
        end
      rescue GithubWebhook::Rejected => error
        error.class
      end
    end
    hashing = Timeout.timeout(10) { reached.pop }
    assert_not hashing.fetch(:transaction_open)
    ApplicationRecord.connection_pool.with_connection do |connection|
      assert_not_equal hashing.fetch(:connection_id), connection.object_id
      Timeout.timeout(10) { yield }
    end
    release << true
    Timeout.timeout(10) { worker.value }
  ensure
    release << true if release
    worker&.join
    OpenSSL::HMAC.define_singleton_method(:hexdigest, original) if original
  end
end
