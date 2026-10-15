# Starts an anonymous preview for one active public share link.
class SharePreviewAuthorizationsController < ApplicationController
  include PublicSharingRequired
  allow_unauthenticated_access
  rate_limit to: 60, within: 1.minute, only: :show, with: -> { head :too_many_requests }
  before_action :set_public_headers

  # @route GET /share/:public_id/preview (share_preview_authorization)
  def show
    return head :not_found if request.base_url != Rails.configuration.x.hub_origin.delete_suffix("/")

    @share_link = ShareLink.find_available(params[:public_id])
    return head :not_found if @share_link.nil?

    grant = SharePreviewGrant.issue!(share_link: @share_link, return_path: params[:return_path].presence)
    response.location = SharePreviewOrigin.current.url \
      @share_link.build_id,
      path: "/__replica/authorize",
      query: { grant: }
    head :found
  rescue ArgumentError, SharingSetting::Disabled
    head :not_found
  end

  private

  # Prevents browsers from retaining the public handoff response.
  def set_public_headers
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
  end
end
