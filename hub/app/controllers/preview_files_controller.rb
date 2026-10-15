# Serves one successful Build from its dedicated preview host.
class PreviewFilesController < ActionController::Base
  include PreviewFileRespondable
  include PreviewControlsRespondable
  before_action :load_preview, only: %i[bridge controls show]
  rescue_from GithubClient::Error, with: :repository_unavailable

  BRIDGE_SOURCE = Rails.root.join \
    "app/javascript/features/install-replica-preview-bridge/index.js"
  BRIDGE_ORIGIN_PLACEHOLDER = "\"__REPLICA_HUB_ORIGIN__\""
  BRIDGE_REVIEW_ENABLED_PLACEHOLDER = "\"__REPLICA_REVIEW_ENABLED__\""
  BRIDGE_TAG = "\n<script src=\"/__replica/bridge/v1.js\"></script>\n"

  # Exchanges a short-lived Hub grant for a host-only preview cookie.
  # @route GET /__replica/preview/authorize (__replica_preview_authorize)
  def authorize
    grant = PreviewGrant.find_valid(params[:grant], build_id: preview_build_id)
    return head :not_found if grant.nil?

    @build = grant.build
    return head :not_found if !available_build? || !authorized?(grant.session)
    return head :not_found if !PreviewGrant.consume(grant)

    cookies.encrypted[preview_cookie_name] = {
      value: preview_cookie_value(grant.session),
      expires: 8.hours.from_now,
      httponly: true,
      path: "/",
      secure: request.ssl?,
      same_site: :lax
    }
    redirect_to grant.return_path
  end

  # Serves an exact Build file or the HTML entry point for a browser route.
  # @route GET /__replica/preview/files (__replica_preview_files)
  # @route GET /__replica/preview/files/*path
  def show
    serve_preview_file @build, html_append: "#{BRIDGE_TAG}#{PreviewControlsRespondable::CONTROLS_TAG}"
  end

  # Serves Hub's bridge from a path that Build files cannot replace.
  # @route GET /__replica/preview/bridge (__replica_preview_bridge)
  def bridge
    source = File.binread(BRIDGE_SOURCE)
    hub_origin = Rails.configuration.x.hub_origin.delete_suffix("/")
    if !source.include?(BRIDGE_ORIGIN_PLACEHOLDER)
      raise "Preview bridge origin placeholder is missing"
    end
    if !source.include?(BRIDGE_REVIEW_ENABLED_PLACEHOLDER)
      raise "Preview bridge review placeholder is missing"
    end

    source = source.sub(BRIDGE_ORIGIN_PLACEHOLDER) { hub_origin.to_json }
    source = source.sub(BRIDGE_REVIEW_ENABLED_PLACEHOLDER) { @build.prototype.reviewable?.to_s.to_json }
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
    render body: source, content_type: "text/javascript; charset=utf-8"
  end

  private

  # Loads one successful Build after checking the signed-in preview cookie.
  def load_preview
    browser_session = preview_session
    return redirect_to_hub if browser_session.nil?

    @build = Build.includes(prototype: :repository).find_by(id: preview_build_id)
    return head :not_found if !available_build?

    head :not_found if !authorized?(browser_session)
  end

  # Reports whether the host names one successful Build in an active repository.
  def available_build?
    @build&.state == "successful" && @build.prototype.repository.installation_state == "active"
  end

  # Confirms that the saved browser session still has repository access.
  def authorized?(browser_session)
    @build.prototype.repository.authorization.authorized?(browser_session.user) &&
      Session.where(id: browser_session.id, user_id: browser_session.user_id).exists?
  end

  # Sends an unauthenticated browser through the trusted Hub origin.
  def redirect_to_hub
    return_path = request.get_header(PreviewPathRouting::ORIGINAL_PATH)
    return_path = "#{return_path}?#{request.query_string}" if request.query_string.present?
    path = Rails.application.routes.url_helpers.preview_build_authorization_path \
      preview_build_id,
      return_path: return_path
    redirect_to "#{Rails.configuration.x.hub_origin.delete_suffix("/")}#{path}", allow_other_host: true
  end

  # Returns the preview cookie name for the current environment.
  def preview_cookie_name
    return :"__Host-replica_preview" if Rails.env.production?

    LocalDevelopment.enabled? ? :replica_local_preview : :replica_preview
  end

  # Returns the preview cookie data for one browser session.
  def preview_cookie_value(browser_session)
    {
      "build_id" => @build.id,
      "session_id" => browser_session.id,
      "expires_at" => 8.hours.from_now.to_i
    }
  end

  # Returns a current browser session when its cookie matches the Build.
  def preview_session
    value = cookies.encrypted[preview_cookie_name]
    return if !value.is_a?(Hash) || value["build_id"].to_i != preview_build_id.to_i
    return if value["expires_at"].to_i <= Time.current.to_i

    Session.includes(:user).find_by(id: value["session_id"])
  end

  # Returns unavailable when GitHub cannot confirm repository access.
  def repository_unavailable
    head :service_unavailable
  end
end
