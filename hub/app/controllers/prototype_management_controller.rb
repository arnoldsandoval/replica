# Lists only branches a repository collaborator may add, alongside editable gallery entries.
class PrototypeManagementController < SuperglueController
  include HasRepositoryWorkspace

  rescue_from GithubClient::Error, with: :repository_unavailable

  # @route GET /repositories/:repository_github_id/prototypes/manage (repository_prototype_management)
  def show
    load_repository_workspace
    return if performed?
    return head :not_found if !@repository.authorization.sufficient?(@repository_permission, minimum: :write)
    page = params[:page]
    return head :not_found if page && (!page.is_a?(String) || !page.match?(/\A[1-9]\d{0,8}\z/))

    @candidate_page = page ? page.to_i : 1
    @candidate_page_path = repository_prototype_management_path(@repository.route_id)
    @registered_prototypes = @repository.reviewable_prototypes.active.registered.order(:branch_name)
    begin
      @unregistered_prototypes, @candidate_page_count = @repository.prototype_candidates.available_page \
        Current.user,
        permission: @repository_permission,
        page: @candidate_page
      head :not_found if @candidate_page > [ @candidate_page_count, 1 ].max
    rescue GithubClient::Error, LocalDevelopment::Error
      @candidate_check_failed = true
      @unregistered_prototypes = []
      @candidate_page_count = 0
    end
  rescue LocalDevelopment::Error => error
    response.status = 422
    response.content_type = "text/plain; charset=utf-8"
    self.response_body = error.message
  end

  private

  # Does not present an incomplete branch list as authoritative.
  def repository_unavailable
    head :service_unavailable
  end
end
