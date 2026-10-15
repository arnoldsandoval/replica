# Shows the default branch's latest successful static Build without review controls.
class ReplicaBrowsesController < SuperglueController
  include HasRepositoryWorkspace

  rescue_from GithubClient::Error, with: :repository_unavailable

  # @route GET /repositories/:repository_github_id/replica (repository_replica_browse)
  def show
    load_repository_workspace
    return if performed?

    owner = @repository.replica_build_owner
    @latest_build = owner&.current_build || owner&.builds&.chronological&.first
    @selected_build = owner&.builds&.where(state: "successful")&.chronological&.first
    @template = { "id" => "default", "name" => t("templates.default.name"), "path" => "/" }
    @preview_path = PreviewGrant.validate_return_path(params.key?(:return_path) ? params[:return_path] : "/")
  rescue ArgumentError
    head :not_found
  end

  private

  # Access failures must not return a successful empty Browse page.
  def repository_unavailable
    head :service_unavailable
  end
end
