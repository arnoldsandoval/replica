# Checks again after rendering or storage reads, which may overlap disabling.
module PublicSharingRequired
  extend ActiveSupport::Concern

  included do
    around_action :check_public_response
  end

  private

  def check_public_response
    yield
    return if @share_link.nil? || response.status >= 400

    ShareLink.with_available_access(@share_link.id) do |available|
      if available
        self.response_body = PublicShareResponseBody.new(response_body, @share_link.id)
      else
        response_body.close if response_body.respond_to?(:close)
        self.response_body = []
        response.status = :not_found
        response.headers.delete("Location")
        response.headers["Cache-Control"] = "private, no-store"
        cookies.delete(share_preview_cookie_name) if respond_to?(:share_preview_cookie_name, true)
      end
    end
  end
end
