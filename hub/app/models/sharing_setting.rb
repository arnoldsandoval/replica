# == Schema Information
#
# Table name: sharing_settings
# Database name: primary
#
#  id                     :integer          not null, primary key
#  public_sharing_enabled :boolean          default(FALSE), not null
#  revision               :integer          default(0), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#
# Check Constraints
#
#  sharing_settings_revision   (revision >= 0)
#  sharing_settings_singleton  (id = 1)
#
# Owns the deployment opt-in, independently of GitHub repository permissions.
class SharingSetting < ApplicationRecord
  class Disabled < StandardError; end
  class Changed < StandardError; end
  class ChangeDenied < StandardError
    attr_reader :reason

    # Exposes only a fixed policy reason, never submitted settings.
    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end

  class << self
    # Missing state also denies sharing, including freshly loaded schemas.
    def enabled?
      where(id: 1, public_sharing_enabled: true).exists?
    end

    # Captures policy before a request starts external authorization work.
    def revision
      where(id: 1).pick(:revision) || 0
    end

    # Rejects operations begun before any intervening deployment-policy change.
    def verify!(expected_revision)
      raise Disabled if !enabled?
      raise Changed if revision != expected_revision
    end

    # Serializes policy, role, freshness, revocations and audit in SQLite.
    def change!(actor:, browser_session:, operation:)
      transaction do
        live_actor = User.where.not(github_id: nil).find_by(id: actor.id, hub_admin: true)
        raise ChangeDenied, :not_authorized if live_actor.nil?

        live_session = Session.find_by(id: browser_session&.id, user_id: live_actor.id)
        raise ChangeDenied, :not_authorized if live_session.nil?
        raise FreshAuthorization::Invalid if !FreshAuthorization.fresh?(live_session)
        raise ChangeDenied, :invalid_operation if !operation.in?(%w[enable disable])

        setting = find_or_create_by!(id: 1)
        enabled = operation == "enable"
        raise ChangeDenied, :state_changed if setting.public_sharing_enabled? == enabled

        setting.update!(public_sharing_enabled: enabled, revision: setting.revision + 1)
        ShareLink.revoke_all!(ShareLink.where(revoked_at: nil), actor: live_actor) if !enabled
        SecurityAuditEvent.record! \
          action: "sharing_settings.#{operation}",
          outcome: "succeeded",
          actor: live_actor,
          context: (Current.security_audit_context || {}).merge(session_id: live_session.id)
      end
    end
  end
end
