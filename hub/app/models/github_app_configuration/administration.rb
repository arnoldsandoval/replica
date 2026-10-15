# Serializes App changes while keeping GitHub requests outside database transactions.
class GithubAppConfiguration::Administration < ActiveRecord::AssociatedObject
  WEBHOOK_LEASE = 5.minutes
  RESET_PHRASE = "delete local GitHub App configuration"
  RECOVERY_PHRASE = "replace credentials for the existing GitHub App"
  CLIENT_SECRET_LIMIT = 4.kilobytes
  PRIVATE_KEY_LIMIT = 16.kilobytes

  class Denied < StandardError
    attr_reader :reason

    # Fixed reasons are safe to translate without exposing credentials or GitHub errors.
    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end

  class InvalidCredentials < StandardError; end
  class ResetDisconnectFailed < StandardError; end

  # Verifies the candidate key before a live browser authorization can commit credentials.
  def replace_credentials!(actor:, browser_session:, expected_version:, client_secret:, private_key:)
    browser_change!(actor:, browser_session:, expected_version:) { }
    record.rotator.verify_credentials!(client_secret:, private_key:)
    browser_change!(actor:, browser_session:, expected_version:) do |live_actor|
      save_credentials!(client_secret:, private_key:)
      audit!("rotate_credentials", actor: live_actor)
    end
  end

  # Host recovery shares validation, not browser authorization or a configurable bypass.
  def recover_credentials!(confirmation:, client_secret:, private_key:)
    raise Denied, :confirmation_required if confirmation != RECOVERY_PHRASE
    raise Denied, :not_configured if LocalDevelopment.enabled?

    version = record.lock_version
    record.with_lock { require_idle_request! }
    record.rotator.verify_credentials!(client_secret:, private_key:)
    record.with_lock do
      raise Denied, :state_changed if record.lock_version != version

      require_idle_request!
      save_credentials!(client_secret:, private_key:)
      Current.set(session: nil, canvas_grant: nil, security_audit_context: { source: "command" }) do
        audit!("recover_credentials", actor: nil)
      end
    end
  end

  # Keeps one desired secret through failed or interrupted remote updates.
  def rotate_webhook!(actor:, browser_session:, expected_version:, operation:)
    token = SecureRandom.uuid
    browser_change!(actor:, browser_session:, expected_version:) do
      valid = (operation == "start" && record.webhook_rotation_state == "idle") ||
        (operation == "retry" && record.webhook_rotation_state == "pending")
      raise Denied, :state_changed if !valid

      if operation == "start"
        record.assign_attributes \
          previous_webhook_secret: record.webhook_secret,
          webhook_secret: SecureRandom.urlsafe_base64(48),
          webhook_secret_rotated_at: Time.current
      end
      record.update! \
        webhook_rotation_state: "pending",
        webhook_request_token: token,
        webhook_request_expires_at: WEBHOOK_LEASE.from_now
    end
    record.with_lock do
      authorize_browser!(actor, browser_session)
      raise Denied, :state_changed if record.webhook_request_token != token ||
        record.webhook_request_expires_at.nil? || record.webhook_request_expires_at <= Time.current
    end
    record.rotator.update_webhook!
    record.with_lock do
      raise Denied, :state_changed if record.webhook_request_token != token ||
        record.webhook_request_expires_at.nil? || record.webhook_request_expires_at <= Time.current

      live_actor = authorize_browser!(actor, browser_session)
      record.update! \
        webhook_rotation_state: "confirmed",
        webhook_request_token: nil,
        webhook_request_expires_at: nil
      audit!("rotate_webhook_secret", actor: live_actor)
    end
  rescue GithubClient::Error, Denied, FreshAuthorization::Invalid
    release_attempt!(token)
    raise
  end

  # Stops overlap only after GitHub acknowledged the saved replacement.
  def finish_webhook!(actor:, browser_session:, expected_version:)
    browser_change!(actor:, browser_session:, expected_version:) do |live_actor|
      raise Denied, :webhook_pending if record.webhook_rotation_state != "confirmed"

      record.update!(previous_webhook_secret: nil, webhook_rotation_state: "idle")
      audit!("finish_webhook_rotation", actor: live_actor)
    end
  end

  # Ends local access without deleting retained collaboration data or the remote App.
  def reset!(actor:, browser_session:, expected_version:, confirmation:)
    raise Denied, :confirmation_required if confirmation != RESET_PHRASE
    raise Denied, :bootstrap_missing if ENV.fetch("REPLICA_BOOTSTRAP_SECRET", "").blank?

    credentials = nil
    browser_change!(actor:, browser_session:, expected_version:) do |live_actor|
      record.repositories.remove_all!
      credentials = SessionRevocation.end_all!(actor: live_actor, browser_session:)
      record.destroy!
      audit!("reset", actor: live_actor)
    end
    begin
      SessionRevocation.disconnect!(credentials)
    rescue ActiveRecord::ActiveRecordError, IOError, SystemCallError, Timeout::Error => error
      Rails.logger.error("App reset committed; live disconnect failed: #{error.class}")
      SecurityAuditEvent.record! \
        action: "github_app.reset_disconnect", outcome: "failed", actor:,
        context: (Current.security_audit_context || {}).merge(github_app_configuration_id: record.id)
      raise ResetDisconnectFailed, "App reset committed; live disconnect failed"
    end
  end

  private

  # SQLite's write transaction covers authorization, state changes, and success evidence.
  def browser_change!(actor:, browser_session:, expected_version:)
    record.with_lock do
      live_actor = authorize_browser!(actor, browser_session)
      raise Denied, :state_changed if record.lock_version != expected_version

      require_idle_request!
      yield live_actor
    end
  end

  # Removed administrators and credentials cannot act using an earlier controller check.
  def authorize_browser!(actor, browser_session)
    live_actor = User.where(id: actor&.id, hub_admin: true).where.not(github_id: nil).first
    live_session = Session.find_by(id: browser_session&.id, user_id: live_actor&.id)
    raise Denied, :not_authorized if live_actor.nil? || live_session.nil? || LocalDevelopment.enabled?
    raise FreshAuthorization::Invalid if !FreshAuthorization.fresh?(live_session)

    live_actor
  end

  # An abandoned attempt permits explicit retry, never an automatic remote mutation.
  def require_idle_request!
    raise Denied, :busy if record.webhook_request_expires_at && record.webhook_request_expires_at > Time.current
  end

  # Old OAuth workflows cannot establish proof against newly stored App credentials.
  def save_credentials!(client_secret:, private_key:)
    record.update! \
      client_secret:, private_key:,
      credential_revision: record.credential_revision + 1,
      webhook_request_token: nil,
      webhook_request_expires_at: nil
    Session.update_all(fresh_authorized_at: nil)
    CanvasGrant.update_all(fresh_authorized_at: nil)
    FreshAuthorization.delete_all
    HubAdminEnrollment.delete_all
  end

  # The token prevents an old failure from releasing a newer request's lease.
  def release_attempt!(token)
    record.class.where(id: record.id, webhook_request_token: token)
      .update_all(webhook_request_token: nil, webhook_request_expires_at: nil, updated_at: Time.current)
  end

  # Only trusted identity and credential context accompanies an administration decision.
  def audit!(operation, actor:)
    SecurityAuditEvent.record! \
      action: "github_app.#{operation}", outcome: "succeeded", actor:,
      context: (Current.security_audit_context || {}).merge(github_app_configuration_id: record.id)
  end
end
