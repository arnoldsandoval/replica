# Offers deployment App status and deliberate reset, never repository-content access.
class GithubAppsController < SuperglueController
  include HasGithubAppAdministration

  before_action :authorize_admin
  before_action :load_configuration
  before_action :confirm_change, only: :destroy
  before_action :authorize_reset, only: :destroy
  rescue_from GithubAppConfiguration::Administration::ResetDisconnectFailed, with: :reset_disconnect_failed

  # @route GET /github_app (github_app)
  def show
    record_security_audit(outcome: "succeeded")
  end

  # @route GET /github_app/reset (reset_github_app)
  def reset_confirmation
    @bootstrap_ready = ENV.fetch("REPLICA_BOOTSTRAP_SECRET", "").present?
    record_security_audit(outcome: "succeeded")
  end

  # @route DELETE /github_app (github_app)
  def destroy
    @configuration.administration.reset! \
      actor: Current.user, browser_session: Current.session,
      expected_version: @expected_version, confirmation: params[:confirmation]
    reset_completed("complete")
  end

  private

  # Match the existing normal administrator boundary before loading App data.
  def authorize_admin
    return if User.where(id: Current.user.id, hub_admin: true).where.not(github_id: nil).exists? &&
      !LocalDevelopment.enabled?

    deny_admin_access
  end

  def authorize_reset
    raise GithubAppConfiguration::Administration::Denied, :confirmation_required if
      params[:confirmation] != GithubAppConfiguration::Administration::RESET_PHRASE

    require_fresh_authorization \
      purpose: :github_app_reset, return_to: reset_github_app_path
  end

  def security_audit_action
    action_name == "destroy" ? "github_app.reset" : "github_app.view"
  end

  def reset_disconnect_failed
    reset_completed("disconnect_failed")
  end

  # A notification failure cannot undo committed database credential revocation.
  def reset_completed(message)
    @security_audit_recorded = true
    reset_session
    Current.session = nil
    redirect_to root_path, alert: t("github_app.reset.#{message}"), status: :see_other
  end
end
