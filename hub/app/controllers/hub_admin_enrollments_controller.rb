# Enrolls an operator only after both bootstrap-secret possession and fresh GitHub sign-in.
class HubAdminEnrollmentsController < SuperglueController
  allow_unauthenticated_access
  before_action { head :not_found if LocalDevelopment.enabled? }
  before_action :resume_session
  rate_limit to: 10, within: 1.minute, only: :create,
    by: -> { trusted_request_ip }, with: -> { head :too_many_requests }
  before_action -> { enforce_security_rate_limit(:oauth_initiation, identity: trusted_request_ip) }, only: :create

  rescue_from HubAdminEnrollment::InvalidProof, with: -> { head :not_found }

  # @route GET /operator/enrollment (hub_admin_enrollment)
  def show
  end

  # @route POST /operator/enrollment (operator_enrollment)
  def create
    enrollment, proof = HubAdminEnrollment.start!(params[:bootstrap_secret])
    configuration = GithubAppConfiguration.current
    raise HubAdminEnrollment::InvalidProof, "Operator authorization failed" if configuration.nil?

    pending = {}
    url = configuration.oauth.authorize_url(pending)
    enrollment.bind_oauth!(pending.fetch(:github_oauth_state))
    pending[:hub_admin_enrollment_proof] = proof
    session.delete(:fresh_authorization_id)
    session.update(pending)
    response.location = url
    head :found
  end

  private

  def security_audit_action
    "hub_admin.enroll" if action_name == "create"
  end
end
