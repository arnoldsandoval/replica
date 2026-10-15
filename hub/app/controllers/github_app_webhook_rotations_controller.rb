# Separates a retriable server-side webhook update from ending old-secret acceptance.
class GithubAppWebhookRotationsController < SuperglueController
  include HasGithubAppAdministration

  before_action :authorize_admin
  before_action :load_configuration
  before_action :confirm_change, only: %i[create destroy]
  before_action :authorize_rotation, only: %i[create destroy]

  # @route GET /github_app/webhook_rotation (github_app_webhook_rotation)
  def show
    record_security_audit(outcome: "succeeded")
  end

  # @route POST /github_app/webhook_rotation (github_app_webhook_rotation)
  def create
    @configuration.administration.rotate_webhook! \
      actor: Current.user, browser_session: Current.session,
      expected_version: @expected_version, operation: params[:operation]
    @security_audit_recorded = true
    redirect_to github_app_webhook_rotation_path,
      notice: t("github_app.webhook.confirmed"), status: :see_other
  end

  # @route DELETE /github_app/webhook_rotation (github_app_webhook_rotation)
  def destroy
    @configuration.administration.finish_webhook! \
      actor: Current.user, browser_session: Current.session, expected_version: @expected_version
    @security_audit_recorded = true
    redirect_to github_app_webhook_rotation_path,
      notice: t("github_app.webhook.finished"), status: :see_other
  end

  private

  # Use the same live normal administrator role as the existing management page.
  def authorize_admin
    return if User.where(id: Current.user.id, hub_admin: true).where.not(github_id: nil).exists? &&
      !LocalDevelopment.enabled?

    deny_admin_access
  end

  def authorize_rotation
    if action_name == "create" && !params[:operation].in?(%w[start retry])
      raise GithubAppConfiguration::Administration::Denied, :confirmation_required
    end
    purpose = action_name == "destroy" ? :github_app_finish_webhook : :github_app_webhook
    require_fresh_authorization \
      purpose:, return_to: github_app_webhook_rotation_path
  end

  def security_audit_action
    return "github_app.view" if action_name == "show"

    action_name == "destroy" ? "github_app.finish_webhook_rotation" : "github_app.rotate_webhook_secret"
  end
end
