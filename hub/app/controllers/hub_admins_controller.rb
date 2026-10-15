# Changes only existing Hub users' explicit roles, never their repository permissions.
class HubAdminsController < SuperglueController
  include FreshAuthorizationRequired

  before_action :authorize_admin
  before_action :load_target, only: %i[edit update]
  before_action :confirm_change, only: %i[create update]
  before_action :authorize_sensitive_action, only: %i[create update]

  rescue_from User::AdminRoleChangeDenied, with: :role_change_denied
  rescue_from ActiveRecord::RecordNotFound, with: :target_not_found
  rescue_from FreshAuthorization::Invalid, with: :authorization_expired
  rescue_from ActiveRecord::RecordInvalid, with: :invalid_user

  # @route GET /hub_admins (hub_admins)
  def index
    relation = User.where(hub_admin: true).where.not(github_id: nil)
    @administrator_count = relation.count
    if params[:before].present?
      return target_not_found if !params[:before].to_s.match?(/\A[1-9]\d{0,17}\z/)

      relation = relation.where(id: ...params[:before].to_i)
    end
    records = relation.order(id: :desc).limit(51).to_a
    @users = records.first(50)
    @next_path = hub_admins_path(before: @users.last.id) if records.length > 50
    record_security_audit(outcome: "succeeded")
  end

  # @route GET /hub_admins/candidates (candidates_hub_admins)
  def candidates
    if !params[:query].nil? && !params[:query].is_a?(String)
      record_security_audit(outcome: "denied")
      render json: { errors: [ t("hub_admins.add_dialog.search_failed") ] }, status: :unprocessable_entity
      return
    end

    query = params[:query].to_s.strip
    relation = User.where(hub_admin: false).where.not(github_id: nil)
    if query.present?
      pattern = "%#{User.sanitize_sql_like(query.first(100))}%"
      relation = relation.where("login LIKE :query ESCAPE '\\' OR name LIKE :query ESCAPE '\\'", query: pattern)
    end
    records = relation.order(:login, :id).limit(51).to_a
    record_security_audit(outcome: "succeeded")
    render \
      json: {
        users: records.first(50).map { { id: _1.id, login: _1.login, name: _1.name } },
        more: records.length > 50
      }
  end

  # @route POST /hub_admins (hub_admins)
  def create
    User.designate_hub_admins! \
      actor: Current.user, browser_session: Current.session, user_ids: params[:user_ids]
    @security_audit_recorded = true
    redirect_to hub_admins_path, notice: t("hub_admins.added"), status: :see_other
  end

  # @route GET /hub_admins/:id/edit (edit_hub_admin)
  def edit
    @operation = @target.hub_admin? ? "revoke" : "designate"
    @last_admin = @target.hub_admin? && User.where(hub_admin: true).where.not(github_id: nil).count <= 1
    record_security_audit(outcome: "succeeded")
  end

  # @route PATCH /hub_admins/:id (hub_admin)
  # @route PUT /hub_admins/:id (hub_admin)
  def update
    @target.change_hub_admin! \
      actor: Current.user, browser_session: Current.session, operation: params[:operation]
    @security_audit_recorded = true
    if Current.user.reload.hub_admin?
      redirect_to hub_admins_path, notice: t("hub_admins.changed"), status: :see_other
    else
      flash.now[:notice] = t("hub_admins.changed")
      render_without_admin_access(status: :ok)
    end
  end

  private

  # Checks the persisted role before exposing users or creating a challenge.
  def authorize_admin
    return if User.where(id: Current.user.id, hub_admin: true).where.not(github_id: nil).exists?

    record_security_audit(outcome: "denied")
    if action_name == "candidates"
      render json: { errors: [ t("hub_admins.errors.not_authorized") ] }, status: :forbidden
      return
    end

    flash.now[:alert] = t("hub_admins.errors.not_authorized")
    render_without_admin_access
  end

  # Only resolved server-owned target IDs enter audit context.
  def load_target
    @target = User.where.not(github_id: nil).find(params[:id])
    Current.security_audit_context = Current.security_audit_context.merge(target_user_id: @target.id)
  end

  def confirm_change
    User.validate_hub_admin_selection!(params[:user_ids]) if action_name == "create"
    return if params[:confirmed] == "1" &&
      (action_name == "create" || params[:operation].in?(%w[designate revoke]))

    role_change_denied(User::AdminRoleChangeDenied.new(:confirmation_required))
  end

  def authorize_sensitive_action
    require_fresh_authorization \
      purpose: :hub_admin_management,
      return_to: action_name == "create" ? hub_admins_path : edit_hub_admin_path(@target)
  end

  def security_audit_action
    return "hub_admin.designate" if action_name == "create"
    return "hub_admin.view" if action_name != "update"

    operation = params[:operation].in?(%w[designate revoke]) ? params[:operation] : "change"
    "hub_admin.#{operation}"
  end

  def role_change_denied(error)
    record_security_audit(outcome: "denied", actor: User.find_by(id: Current.user.id))
    if error.reason == :not_authorized
      flash.now[:alert] = t("hub_admins.errors.not_authorized")
      render_without_admin_access
    else
      redirect_to hub_admins_path, alert: t("hub_admins.errors.#{error.reason}"), status: :see_other
    end
  end

  # A removed operator may have no repository, so denial must render on its own.
  def render_without_admin_access(status: :forbidden)
    @access_denied = true
    @users = []
    render "hub_admins/index", status:
  end

  def target_not_found
    record_security_audit(outcome: "denied")
    redirect_to hub_admins_path, alert: t("hub_admins.errors.invalid_target"), status: :see_other
  end

  def authorization_expired
    record_security_audit(outcome: "denied")
    redirect_to hub_admins_path, alert: t("fresh_authorization.required"), status: :see_other
  end

  def invalid_user(error)
    raise error if error.record.is_a?(SecurityAuditEvent)

    record_security_audit(outcome: "failed")
    redirect_to hub_admins_path, alert: t("hub_admins.errors.save_failed"), status: :see_other
  end
end
