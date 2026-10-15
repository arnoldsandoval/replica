# Shares App form/error mechanics; each controller owns its normal administrator guard.
module HasGithubAppAdministration
  extend ActiveSupport::Concern
  include FreshAuthorizationRequired

  included do
    rescue_from GithubAppConfiguration::Administration::Denied, with: :administration_denied
    rescue_from FreshAuthorization::Invalid, with: :authorization_expired
    rescue_from GithubAppConfiguration::Administration::InvalidCredentials,
      GithubAppConfiguration::Rotator::IdentityMismatch, with: :invalid_credentials
    rescue_from GithubClient::Error, with: :github_failed
    rescue_from ActiveRecord::RecordInvalid, with: :save_failed
    rescue_from ActiveRecord::RecordNotFound, ActiveRecord::StaleObjectError,
      GithubAppConfiguration::Superseded, with: :configuration_changed
  end

  private

  # Only server-resolved App IDs belong in request audit context.
  def load_configuration
    @configuration = GithubAppConfiguration.current
    if @configuration
      Current.security_audit_context = Current.security_audit_context.merge(
        github_app_configuration_id: @configuration.id
      )
    elsif controller_path != "github_apps" || action_name != "show"
      raise GithubAppConfiguration::Administration::Denied, :not_configured
    end
  end

  # A stale confirmation cannot target a new singleton configuration.
  def confirm_change
    valid = params[:confirmed] == "1" && params[:configuration_id].is_a?(String) &&
      params[:configuration_id].match?(/\A[1-9]\d{0,17}\z/) &&
      params[:configuration_id].to_i == @configuration.id &&
      params[:expected_version].is_a?(String) &&
      params[:expected_version].match?(/\A(?:0|[1-9]\d{0,17})\z/)
    raise GithubAppConfiguration::Administration::Denied, :confirmation_required if !valid

    @expected_version = params[:expected_version].to_i
  end

  # Denial is independent of repository access, including for a removed administrator.
  def deny_admin_access
    record_security_audit(outcome: "denied")
    @access_denied = true
    @users = []
    flash.now[:alert] = t("github_app.errors.not_authorized")
    render "hub_admins/index", status: :forbidden
  end

  def administration_denied(error)
    return deny_admin_access if error.reason == :not_authorized

    record_security_audit(outcome: "denied")
    redirect_to github_app_path, alert: t("github_app.errors.#{error.reason}"), status: :see_other
  end

  def authorization_expired
    record_security_audit(outcome: "denied")
    redirect_to github_app_path, alert: t("fresh_authorization.required"), status: :see_other
  end

  def configuration_changed
    administration_denied(GithubAppConfiguration::Administration::Denied.new(:state_changed))
  end

  def invalid_credentials
    record_security_audit(outcome: "failed")
    redirect_to edit_github_app_credentials_path,
      alert: t("github_app.errors.invalid_credentials"), status: :see_other
  end

  def github_failed
    record_security_audit(outcome: "failed")
    redirect_to github_app_path, alert: t("github_app.errors.github_failed"), status: :see_other
  end

  def save_failed(error)
    raise error if error.record.is_a?(SecurityAuditEvent)

    record_security_audit(outcome: "failed")
    redirect_to github_app_path, alert: t("github_app.errors.save_failed"), status: :see_other
  end
end
