# Opens a reviewable pull request that synchronizes the Replica workflow.
class RepositoryWorkflowInstallationsController < ApplicationController
  rescue_from GithubClient::Error, with: :repository_unavailable

  # @route POST /repositories/:repository_github_id/workflow_installation (repository_workflow_installation)
  def create
    return head :not_found if LocalDevelopment.enabled?

    repository = Repository.active.find_by!(github_id: params[:repository_github_id])
    configuration = GithubAppConfiguration.current
    authorized = repository.authorization.authorized? \
      Current.user,
      minimum: :write,
      fresh: true,
      configuration: configuration
    return head :not_found if !authorized
    return if !enforce_security_rate_limit(:workflow_installation)

    open_pull_request(repository, configuration)
  end

  private

  # Returns to the repository with a useful reason when GitHub cannot open the PR.
  def open_pull_request(repository, configuration)
    pull_request = repository.workflow_installation.create_pull_request!(configuration:)
    redirect_to \
      pull_request_url(repository, pull_request.fetch("number")),
      allow_other_host: true,
      status: :see_other
  rescue Repository::WorkflowInstallation::AlreadyInstalled
    redirect_to \
      repository_path(repository.github_id),
      notice: I18n.t("repositories.show.workflow.already_current"),
      status: :see_other
  rescue Repository::WorkflowInstallation::BranchConflict
    workflow_error(repository, :branch_conflict)
  rescue GithubClient::Forbidden, GithubClient::NotFound
    workflow_error(repository, :permissions)
  rescue GithubClient::RateLimited
    workflow_error(repository, :rate_limited)
  rescue GithubClient::Error
    workflow_error(repository, :github_error)
  rescue ArgumentError
    workflow_error(repository, :unconfigured)
  end

  def repository_unavailable
    render \
      plain: I18n.t("repositories.show.workflow.errors.access_unavailable"),
      status: :service_unavailable
  end

  # Uses the existing repository alert without exposing GitHub's response body.
  def workflow_error(repository, reason)
    redirect_to \
      repository_path(repository.github_id),
      alert: I18n.t("repositories.show.workflow.errors.#{reason}"),
      status: :see_other
  end

  # Builds a GitHub URL from validated repository and pull request identities.
  def pull_request_url(repository, number)
    github_url = Rails.configuration.x.github_url.delete_suffix("/")
    "#{github_url}/#{repository.github_path}/pull/#{number}"
  end
end
