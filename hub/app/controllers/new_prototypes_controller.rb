# Presents the prototype brief for one readable repository.
class NewPrototypesController < SuperglueController
  include HasRepositoryTemplates

  rescue_from GithubClient::Error, ArtifactStore::Error, Build::Templates::InvalidManifest,
    with: :repository_unavailable

  # @route GET /repositories/:repository_github_id/new (repository_new_prototype)
  def show
    load_repository_templates
  end

  private

  # Does not expose a repository when GitHub cannot confirm access.
  def repository_unavailable
    head :service_unavailable
  end
end
