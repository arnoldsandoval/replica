# Records installation status only for this Hub's configured owner.
class GithubAppConfiguration::Installation < ActiveRecord::AssociatedObject
  class OwnerMismatch < StandardError; end

  # Fetches the current installation from GitHub and saves its status.
  def reconcile!(installation_id)
    snapshot = record.credential_snapshot
    GithubAppConfiguration.with_credentials!(**snapshot) { }
    record_status!(remote_installation(installation_id), credentials: snapshot)
  end

  # Commits browser setup and its audit only after all GitHub requests finish.
  def install!(installation_id)
    credentials = record.credential_snapshot
    GithubAppConfiguration.with_credentials!(**credentials) { }
    payload = remote_installation(installation_id)
    verify_owner!(payload.fetch("account"))
    state = state_for(payload, nil)
    installation_id = payload.fetch("id").to_i
    snapshot = if state == "active"
      token = record.tokens.for_installation(installation_id)
      record.repositories.snapshot(token:)
    end

    GithubAppConfiguration.with_credentials!(**credentials) do
      save_status!(payload, state:)
      state == "active" ? record.repositories.synchronize!(snapshot:) : record.repositories.remove_all!
      SecurityAuditEvent.record! \
        action: "github_app_setup.install",
        outcome: "succeeded",
        context: (Current.security_audit_context || {}).merge(github_app_configuration_id: record.id)
    end
  end

  # Retains verified webhook status even when its later repository refresh fails.
  def record_status!(payload, action: nil, credentials: record.credential_snapshot)
    verify_owner!(payload.fetch("account"))
    return if stale_removal?(payload, action)

    state = state_for(payload, action)
    save_status!(payload, state:, credentials:)
    state == "active" ? record.repositories.synchronize! : record.repositories.remove_all!
  end

  private

  # Fetches the installation without holding a local write transaction.
  def remote_installation(installation_id)
    record.github_client.installations.get \
      installation_id,
      token: record.tokens.app
  end

  # Applies the verified status without performing GitHub I/O.
  def save_status!(payload, state:, credentials: record.credential_snapshot)
    GithubAppConfiguration.with_credentials!(**credentials) do
      record.with_lock do
        checked_at = Time.current
        record.assign_attributes \
          installation_id: payload.fetch("id").to_i,
          installation_state: state,
          owner_login: payload.fetch("account").fetch("login"),
          installed_at: state == "active" ? record.installed_at || checked_at : record.installed_at,
          suspended_at: state == "suspended" ? record.suspended_at || checked_at : nil
        if record.changed?
          record.installation_checked_at = checked_at
          record.save!
        else
          # Poll freshness alone must not invalidate an administrator's confirmation.
          record.update_columns(installation_checked_at: checked_at)
        end
      end
    end
  end

  # Confirms the installation belongs to the configured GitHub owner.
  def verify_owner!(account)
    matches = account.fetch("id").to_i == record.owner_github_id &&
      account.fetch("type") == record.owner_type
    raise OwnerMismatch, "Installation owner does not match the configured GitHub App owner" if !matches
  end

  # Converts GitHub's installation details into a status Hub stores.
  def state_for(payload, action)
    return "removed" if action == "deleted"

    return "suspended" if action == "suspend" || payload["suspended_at"].present?

    "active"
  end

  # Ignores a delayed removal for an installation that is no longer current.
  def stale_removal?(payload, action)
    action == "deleted" && record.installation_id.present? &&
      record.installation_id != payload.fetch("id").to_i
  end
end
