# Issues short-lived device proofs without exposing browser cookies to the extension.
class CanvasApi::PairingsController < ActionController::API
  include CanvasApiCompatibility
  include SecurityAuditing
  rate_limit to: 10, within: 1.minute, only: :create, name: "create",
    by: -> { trusted_request_ip }, with: -> { head :too_many_requests }
  rate_limit to: 60, within: 1.minute, only: :show, name: "show",
    by: -> { trusted_request_ip }, with: -> { head :too_many_requests }

  before_action { response.headers["Cache-Control"] = "no-store" }
  rescue_from GithubClient::Error, with: -> { head :service_unavailable }

  # @route POST /api/canvas/pairings (canvas_api_pairings)
  def create
    name = params.require(:repository)
    return head :bad_request if !name.is_a?(String) ||
      !name.match?(%r{\A[^/\s]+/[^/\s]+\z})

    repository = @repository = Repository.active.where("LOWER(name_with_owner) = ?", name.downcase).first
    return head :not_found if repository.nil?

    pairing, device_code, refresh_token = CanvasPairing.start!(repository, renewable: params[:renewable] == true)
    render \
      json: {
        deviceCode: device_code,
        refreshToken: refresh_token,
        userCode: pairing.user_code,
        verificationUrl: "#{Rails.configuration.x.hub_origin.delete_suffix('/')}#{canvas_pairing_path(pairing.user_code)}",
        expiresAt: pairing.expires_at.iso8601,
        intervalSeconds: 3
      },
      status: :created
  end

  # @route POST /api/canvas/pairings/token (canvas_api_pairing_token)
  def show
    status, credentials, pairing = CanvasPairing.consume(params.require(:device_code))
    if status == "expired"
      record_security_audit \
        outcome: "denied",
        repository: pairing&.repository,
        actor: nil,
        context: pairing ? { canvas_pairing_id: pairing.id } : {}
    end
    return render json: { status: } if credentials.nil?

    render json: credentials.fetch(:grant).credentials(credentials.fetch(:secret)).merge(status:)
  rescue ActiveRecord::RecordNotFound, SessionRevocation::Superseded, GithubAppConfiguration::Superseded
    record_security_audit(outcome: "denied", actor: nil)
    render json: { status: "expired" }
  end

  private

  def security_audit_action
    action_name == "create" ? "canvas_pairing.create" : "canvas_pairing.consume"
  end
end
