# Lets connecting and disconnecting Copilot use the same one-use GitHub check as other admin actions.
class AddCopilotConnectionToFreshAuthorizationPurposes < ActiveRecord::Migration[8.1]
  PREVIOUS = "purpose IN ('never_expiring_share', 'analytics_destination', 'hub_admin_management', " \
    "'sharing_settings', 'session_revocation', 'github_app_reset', 'github_app_credentials', " \
    "'github_app_webhook', 'github_app_finish_webhook')".freeze
  CURRENT = "purpose IN ('never_expiring_share', 'analytics_destination', 'hub_admin_management', " \
    "'sharing_settings', 'session_revocation', 'github_app_reset', 'github_app_credentials', " \
    "'github_app_webhook', 'github_app_finish_webhook', 'copilot_connection', 'copilot_disconnection')".freeze

  def change
    remove_check_constraint :fresh_authorizations, PREVIOUS, name: "fresh_authorizations_purpose"
    add_check_constraint :fresh_authorizations, CURRENT, name: "fresh_authorizations_purpose"
  end
end
