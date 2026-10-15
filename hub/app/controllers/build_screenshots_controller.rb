# Serves retained screenshots after GitHub confirms repository access.
class BuildScreenshotsController < ApplicationController
  include ArtifactRespondable

  rescue_from GithubClient::Error, with: :repository_unavailable

  # @route GET /repositories/:repository_github_id/prototypes/:prototype_id/builds/:build_number/screenshots/:size (repository_prototype_build_screenshot)
  def show
    repository = Repository.find_by_route_id!(params[:repository_github_id])
    return head :not_found if !repository.authorization.authorized?(Current.user)

    prototype = repository.reviewable_prototypes.find(params[:prototype_id])
    build = prototype.builds.where(state: "successful").find_by!(number: params[:build_number])
    size = params[:size]
    return head :bad_request if params[:theme].present? && !%w[light dark].include?(params[:theme])

    send_artifact \
      build.screenshot_path(size, theme: params[:theme]),
      fallback: params[:theme] == "dark" ? build.screenshot_path(size) : nil,
      content_type: "image/png",
      filename: "build-#{build.number}-#{size}.png"
  end

  private

  # Returns unavailable when GitHub cannot confirm repository access.
  def repository_unavailable
    head :service_unavailable
  end
end
