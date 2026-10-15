module HasRepositoryWorkspace
  extend ActiveSupport::Concern

  REPOSITORY_SELECTOR_CACHE_TTL = 5.minutes

  included do
    helper_method :hub_repository_workspace
  end

  private

  # Loads one readable repository and the repository choices for the workspace.
  def load_repository_workspace(fresh: false)
    github_id = params[:github_id] || params[:repository_github_id]
    @repository = Repository.find_by_route_id!(github_id)
    configuration = GithubAppConfiguration.current
    @repository_permission = @repository.authorization.permission_for(Current.user, configuration:, fresh:)
    if !@repository.authorization.sufficient?(@repository_permission, minimum: :read)
      return head :not_found
    end

    @repositories = authorized_repositories(configuration, including: @repository)
  end

  # Returns active repositories from a cached list of current GitHub permissions.
  def authorized_repositories(configuration, including: nil, cache: Rails.cache)
    repositories = workspace_repositories
    cache_key = [
      "repository-selector",
      Current.user.github_id || Current.user.id,
      configuration&.cache_key_with_version,
      repositories.cache_key_with_version
    ]
    route_ids = cache.fetch(cache_key, expires_in: REPOSITORY_SELECTOR_CACHE_TTL) do
      repositories.filter_map do |repository|
        if repository == including || repository.authorization.authorized?(Current.user, configuration:)
          repository.route_id
        end
      rescue GithubClient::Error => error
        @repository_navigation_unavailable = true
        Rails.logger.warn("Repository navigation permission check failed: #{error.class}")
        nil
      end
    end

    authorized = if LocalDevelopment.enabled?
      repositories.where(id: route_ids).to_a
    else
      repositories.where(github_id: route_ids).to_a
    end
    authorized << including if including && authorized.exclude?(including)
    authorized.sort_by(&:name_with_owner)
  end

  # Optional navigation must not turn repository availability into a Hub access rule.
  def hub_repository_workspace
    return @hub_repository_workspace if defined?(@hub_repository_workspace)

    @hub_repository_workspace = { repository: nil, repositories: [], permission: nil, error: nil }
    configuration = GithubAppConfiguration.current
    repositories = authorized_repositories(configuration)
    if @repository_navigation_unavailable
      @hub_repository_workspace[:error] = I18n.t("hub_administration_workspace.repositories_unavailable")
    end
    requested_id = params[:repository_github_id].presence
    repository = requested_id ? repositories.find { _1.route_id.to_s == requested_id.to_s } : repositories.first
    if repository.nil?
      if requested_id
        @hub_repository_workspace[:error] = I18n.t("hub_administration_workspace.repository_unavailable")
      end
      return @hub_repository_workspace
    end

    permission = repository.authorization.permission_for(Current.user, configuration:)
    if !repository.authorization.sufficient?(permission, minimum: :read)
      @hub_repository_workspace[:error] = I18n.t("hub_administration_workspace.repository_unavailable")
      return @hub_repository_workspace
    end

    @hub_repository_workspace.merge!(repository:, repositories:, permission:)
  rescue GithubClient::Error => error
    Rails.logger.warn("Repository navigation permission check failed: #{error.class}")
    @hub_repository_workspace[:error] = I18n.t("hub_administration_workspace.repositories_unavailable")
    @hub_repository_workspace
  end

  # Keeps optional navigation and audit choices within the normal repository mode.
  def workspace_repositories
    repositories = Repository.active
    repositories = LocalDevelopment.enabled? ? repositories.where(github_id: nil) :
      repositories.where(local_path: nil)
    repositories.order(:name_with_owner)
  end
end
