# Confirms Hub access before sending a browser to one Build preview host.
class PreviewAuthorizationsController < ApplicationController
  allow_unauthenticated_access
  rescue_from GithubClient::Error, with: :repository_unavailable

  # @route GET /preview/builds/:build_id/authorize (preview_build_authorization)
  def show
    return head :not_found if request.base_url != Rails.configuration.x.hub_origin.delete_suffix("/")

    resume_session
    return continue_after_authentication if Current.user.nil?

    @build = successful_build
    return head :not_found if !repository.authorization.authorized?(Current.user)

    grant = PreviewGrant.issue! \
      build: @build,
      session: Current.session,
      return_path: params[:return_path].presence || @build.prototype.preview_start_page
    response.location = PreviewOrigin.current.url \
      @build.id,
      path: "/__replica/authorize",
      query: { grant: }
    head :found
  rescue ActiveRecord::RecordNotFound, ArgumentError
    head :not_found
  end

  private

  # Loads one successful Build through an active repository.
  def successful_build
    Build.joins(prototype: :repository)
      .includes(prototype: :repository)
      .merge(Repository.active)
      .where(state: "successful")
      .find(params[:build_id])
  end

  # Returns the Build's repository after the scoped lookup succeeds.
  def repository
    @build.prototype.repository
  end

  # Remembers the authorization route and sends a signed-out user to Hub.
  def continue_after_authentication
    session[:authentication_return_to] = request.fullpath
    redirect_to root_path
  end

  # Returns unavailable when GitHub cannot confirm repository access.
  def repository_unavailable
    head :service_unavailable
  end
end
