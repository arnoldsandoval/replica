# Shows one public Build share without requiring GitHub sign-in.
class SharedBuildsController < SuperglueController
  include PublicSharingRequired
  allow_unauthenticated_access
  rate_limit to: 60, within: 1.minute, only: :show, with: -> { head :too_many_requests }
  before_action :set_public_headers

  # @route GET /share/:public_id (shared_build)
  def show
    @share_link = ShareLink.find_available(params[:public_id])
    head :not_found if @share_link.nil?
  end

  private

  # Prevents browsers from retaining public share details.
  def set_public_headers
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
  end
end
