# Changes the deployment opt-in without granting access to repository content.
class SharingSettingsController < SuperglueController
  include FreshAuthorizationRequired

  before_action :authorize_admin
  before_action :confirm_change, only: :update
  before_action :authorize_sensitive_action, only: :update

  rescue_from SharingSetting::ChangeDenied, with: :change_denied
  rescue_from FreshAuthorization::Invalid, with: :authorization_expired
  rescue_from ActiveRecord::RecordInvalid, with: :invalid_setting

  # @route GET /sharing_settings (sharing_settings)
  def show
    @enabled = SharingSetting.enabled?
    record_security_audit(outcome: "succeeded")
  end

  # @route PATCH /sharing_settings (sharing_settings)
  # @route PUT /sharing_settings (sharing_settings)
  def update
    SharingSetting.change! \
      actor: Current.user,
      browser_session: Current.session,
      operation: params[:operation]
    @security_audit_recorded = true
    redirect_to sharing_settings_path, notice: t("sharing_settings.changed"), status: :see_other
  end

  private

  # Check the saved role before exposing state or initiating a challenge.
  def authorize_admin
    return if User.where(id: Current.user.id, hub_admin: true).where.not(github_id: nil).exists?

    record_security_audit(outcome: "denied")
    @access_denied = true
    flash.now[:alert] = t("sharing_settings.errors.not_authorized")
    render :show, status: :forbidden
  end

  def confirm_change
    return if params[:confirmed] == "1" && params[:operation].in?(%w[enable disable])

    change_denied(SharingSetting::ChangeDenied.new(:confirmation_required))
  end

  def authorize_sensitive_action
    require_fresh_authorization \
      purpose: :sharing_settings,
      return_to: sharing_settings_path
  end

  def security_audit_action
    return "sharing_settings.view" if action_name != "update"

    operation = params[:operation].in?(%w[enable disable]) ? params[:operation] : "change"
    "sharing_settings.#{operation}"
  end

  def change_denied(error)
    record_security_audit(outcome: "denied", actor: User.find_by(id: Current.user.id))
    if error.reason == :not_authorized
      @access_denied = true
      flash.now[:alert] = t("sharing_settings.errors.not_authorized")
      render :show, status: :forbidden
    else
      redirect_to \
        sharing_settings_path,
        alert: t("sharing_settings.errors.#{error.reason}"),
        status: :see_other
    end
  end

  def authorization_expired
    record_security_audit(outcome: "denied")
    redirect_to sharing_settings_path, alert: t("fresh_authorization.required"), status: :see_other
  end

  def invalid_setting(error)
    raise error if error.record.is_a?(SecurityAuditEvent)

    record_security_audit(outcome: "failed")
    redirect_to sharing_settings_path, alert: t("sharing_settings.errors.save_failed"), status: :see_other
  end
end
