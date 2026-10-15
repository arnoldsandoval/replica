# Serves only declared template screenshots after checking repository read access.
class TemplateScreenshotsController < ApplicationController
  include ArtifactRespondable

  rescue_from GithubClient::Error, Build::Templates::InvalidManifest, ArtifactStore::Error,
    with: :repository_unavailable

  # @route GET /repositories/:repository_github_id/templates/:template_id/builds/:build_id/screenshots/:size (repository_template_screenshot)
  def show
    repository = Repository.find_by_route_id!(params[:repository_github_id])
    return head :not_found if !repository.authorization.authorized?(Current.user)

    owner = repository.replica_build_owner
    build = owner&.builds&.where(state: "successful")&.find(params[:build_id])
    return head :not_found if !build

    id = params[:template_id]
    return head :not_found if id != "default" && build.templates.entries.none? { _1.fetch("id") == id }

    return head :bad_request if params[:theme].present? && !%w[light dark].include?(params[:theme])

    send_artifact \
      build.screenshot_path(params[:size], template_id: id, theme: params[:theme]),
      fallback: params[:theme] == "dark" ? build.screenshot_path(params[:size], template_id: id) : nil,
      content_type: "image/png",
      filename: "#{id}-#{params[:size]}.png"
  end

  private

  def repository_unavailable
    head :service_unavailable
  end
end
