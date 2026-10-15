# Serves one public Build share from its dedicated preview host.
class SharedPreviewFilesController < ActionController::Base
  include PublicSharingRequired
  include PreviewFileRespondable
  include PreviewControlsRespondable
  before_action :load_preview, only: %i[controls show]

  # Exchanges a public share grant for a host-only preview cookie.
  # @route GET /__replica/share/authorize (__replica_share_authorize)
  def authorize
    response.headers["Cache-Control"] = "private, no-store"
    grant = SharePreviewGrant.find_valid(params[:grant], build_id: preview_build_id)
    return head :not_found if grant.nil?

    @share_link = grant.share_link
    @build = @share_link.build
    return head :not_found if !SharePreviewGrant.consume(grant)

    cookie_expiration = [ 8.hours.from_now, @share_link.effective_expires_at ].compact.min
    cookies.encrypted[share_preview_cookie_name] = {
      value: {
        "build_id" => @build.id,
        "share_link_id" => @share_link.id,
        "expires_at" => cookie_expiration.to_i
      },
      expires: cookie_expiration,
      httponly: true,
      path: "/",
      secure: request.ssl?,
      same_site: :lax
    }
    redirect_to grant.return_path
  end

  # Serves an exact shared Build file or its HTML entry point.
  # @route GET /__replica/share/files (__replica_share_files)
  # @route GET /__replica/share/files/*path
  def show
    serve_preview_file @build, html_append: PreviewControlsRespondable::CONTROLS_TAG
  end

  # Returns not found for paths reserved from retained Build files.
  # @route GET /__replica/share/not_found (__replica_share_not_found)
  def unavailable
    response.headers["Cache-Control"] = "private, no-store"
    head :not_found
  end

  private

  # Loads one Build after checking a current public share link.
  def load_preview
    response.headers["Cache-Control"] = "private, no-store"
    value = share_preview_cookie
    return head :not_found if value.nil?

    @share_link = ShareLink.includes(build: { prototype: :repository })
      .find_by(id: value["share_link_id"])
    return head :not_found if @share_link.nil?
    return head :not_found if @share_link.build_id != preview_build_id
    return head :not_found if !@share_link.available?

    @build = @share_link.build
  end

  # Returns the public share cookie name for the current environment.
  def share_preview_cookie_name
    Rails.env.production? ? :"__Host-replica_share_preview" : :replica_share_preview
  end

  # Returns a current public share cookie for this Build.
  def share_preview_cookie
    value = cookies.encrypted[share_preview_cookie_name]
    return if !value.is_a?(Hash) || value["build_id"].to_i != preview_build_id.to_i
    return if value["expires_at"].to_i <= Time.current.to_i

    value
  end
end
