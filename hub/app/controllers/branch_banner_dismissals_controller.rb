# Saves personal registration-banner preferences without changing the branch.
class BranchBannerDismissalsController < ApplicationController
  rescue_from GithubClient::Error, with: :repository_unavailable

  # @route POST /repositories/:repository_github_id/prototypes/:prototype_id/branch_banner_dismissal (repository_prototype_branch_banner_dismissal)
  def create
    repository = Repository.find_by_route_id!(params[:repository_github_id])
    authorized = repository.authorization.authorized? \
      Current.user,
      minimum: :write,
      fresh: true
    return head :not_found if !authorized

    prototype = repository.reviewable_prototypes.find(params[:prototype_id])
    BranchBannerDismissal.record!(user: Current.user, prototype:)

    redirect_to repository_path(repository.route_id), status: :see_other
  rescue LocalDevelopment::Error => error
    response.status = 422
    response.content_type = "text/plain; charset=utf-8"
    self.response_body = error.message
  end

  private

  # Fails closed when GitHub cannot confirm current repository access.
  def repository_unavailable
    head :service_unavailable
  end
end
