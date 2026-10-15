# Exchanges the private refresh secret only after fresh repository authorization.
class CanvasApi::RenewalsController < ActionController::API
  include CanvasApiCompatibility
  include SecurityAuditing
  before_action { response.headers["Cache-Control"] = "no-store" }
  rate_limit to: 60, within: 1.minute, by: -> { trusted_request_ip }, with: -> { head :too_many_requests }
  rescue_from GithubClient::Error, with: -> { head :service_unavailable }
  rescue_from CanvasGrant::Expired, ActiveRecord::RecordNotFound, with: -> { head :unauthorized }
  rescue_from SessionRevocation::Superseded, GithubAppConfiguration::Superseded, with: -> { head :unauthorized }

  # @route POST /api/canvas/connection/renewal (canvas_api_connection_renewal)
  def create
    grant = CanvasGrant.for_refresh(params.require(:refresh_token))
    return head :unauthorized if grant.nil?
    @repository = grant.repository
    @security_audit_actor = grant.user
    generation = SessionRevocation.current.generation
    configuration = GithubAppConfiguration.current
    snapshot = configuration&.credential_snapshot || { configuration_id: nil, credential_revision: nil }
    return head :forbidden if !grant.repository.authorization.authorized?(grant.user, fresh: true, configuration:)

    credentials = SessionRevocation.with_generation!(generation) do
      if LocalDevelopment.enabled?
        grant.renew!
      else
        GithubAppConfiguration.with_credentials!(**snapshot) { grant.renew! }
      end
    end
    render json: credentials
  end

  # @route DELETE /api/canvas/connection/renewal (canvas_api_connection_renewal)
  def destroy
    grant = CanvasGrant.for_refresh(params.require(:refresh_token))
    if grant.nil?
      record_security_audit(outcome: "denied", actor: nil)
      return head :no_content
    end
    grant&.revoke!
    head :no_content
  end

  private

  def security_audit_action
    action_name == "create" ? "canvas_connection.renew" : "canvas_connection.revoke"
  end
end
