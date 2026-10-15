# Shows only the selected repository's administrator-facing delivery settings.
class AnalyticsController < SuperglueController
  include HasRepositoryWorkspace

  rescue_from GithubClient::Error, with: -> { head :service_unavailable }

  # @route GET /repositories/:repository_github_id/analytics (repository_analytics)
  def show
    load_repository_workspace(fresh: true)
    return if performed?
    return head :not_found if !@repository.authorization.sufficient?(@repository_permission, minimum: :admin)

    @destinations = @repository.analytics_destinations.order(:provider).to_a
    latest_failed_ids = Analytics::Delivery.where(
      repository: @repository, destination_id: @destinations.map(&:id), state: "failed"
    ).group(:destination_id).maximum(:id).values
    @failure_codes = Analytics::Delivery.where(id: latest_failed_ids)
      .pluck(:destination_id, :failure_code).to_h
  end
end
