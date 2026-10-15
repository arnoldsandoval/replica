# Halts sensitive mutations without saving their payload or replaying them after OAuth.
module FreshAuthorizationRequired
  extend ActiveSupport::Concern

  private

  # Supplies the same explicit challenge contract to browser and canvas consumers.
  def require_fresh_authorization(purpose:, return_to: root_path)
    credential = Current.canvas_grant || Current.session
    return true if FreshAuthorization.fresh?(credential)

    record_security_audit(outcome: "denied") if security_audit_action
    challenge = FreshAuthorization.start! \
      credential:, purpose:, return_to: Current.canvas_grant ? root_path : return_to
    url = "#{Rails.configuration.x.hub_origin.delete_suffix('/')}#{fresh_authorization_path(challenge.public_id)}"
    if Current.canvas_grant
      render \
        json: {
          code: "fresh_authorization_required",
          errors: [ I18n.t("fresh_authorization.required") ],
          authorization: { url:, expiresAt: challenge.expires_at.iso8601 }
        },
        status: :forbidden
    else
      redirect_to fresh_authorization_path(challenge.public_id), status: :see_other
    end
    false
  rescue FreshAuthorization::Invalid
    if Current.canvas_grant
      render json: { errors: [ I18n.t("fresh_authorization.failure") ] }, status: :unauthorized
    else
      redirect_to root_path, alert: I18n.t("fresh_authorization.failure"), status: :see_other
    end
    false
  end
end
