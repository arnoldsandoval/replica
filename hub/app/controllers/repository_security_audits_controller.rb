# Authorizes each read with GitHub before selecting only this repository's audit records.
class RepositorySecurityAuditsController < SuperglueController
  include HasRepositoryWorkspace
  include HasSecurityAuditPage
  rescue_from GithubClient::Error, with: -> { head :service_unavailable }

  # @route GET /repositories/:repository_github_id/security_audit (repository_security_audit)
  def show
    load_repository_workspace(fresh: true)
    return if performed?
    return head :not_found if !@repository.authorization.sufficient?(@repository_permission, minimum: :admin)

    load_audit_scopes
    load_audit_events \
      SecurityAuditEvent.retained.where(repository: @repository),
      path: repository_security_audit_path(@repository.route_id)
    record_security_audit(outcome: "succeeded")
  end
end
