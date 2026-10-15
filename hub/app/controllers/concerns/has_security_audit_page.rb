# Shares bounded pagination without sharing authorization between audit scopes.
module HasSecurityAuditPage
  extend ActiveSupport::Concern

  private

  # Choices require their own permission; readable repository navigation is not proof.
  def load_audit_scopes
    @audit_scopes = []
    if User.where(id: Current.user.id, hub_admin: true).where.not(github_id: nil).exists?
      @audit_scopes << { id: "hub", label: I18n.t("security_audit.hub_scope"), path: security_audit_path }
    end
    configuration = GithubAppConfiguration.current
    workspace_repositories.each do |repository|
      permission = if repository == @repository
        @repository_permission
      else
        repository.authorization.permission_for(Current.user, configuration:, fresh: true)
      end
      if repository.authorization.sufficient?(permission, minimum: :admin)
        @audit_scopes << {
          id: repository.route_id.to_s,
          label: repository.name_with_owner,
          path: repository_security_audit_path(repository.route_id)
        }
      end
    rescue GithubClient::Error => error
      Rails.logger.warn("Audit scope permission check failed: #{error.class}")
      @audit_scopes_unavailable = true
    end
  end

  def load_audit_events(relation, path:)
    if params[:before].present?
      raise ActiveRecord::RecordNotFound if !params[:before].to_s.match?(/\A[1-9]\d{0,17}\z/)

      relation = relation.where(id: ...params[:before].to_i)
    end
    records = relation.order(id: :desc).limit(51).to_a
    @events = records.first(50)
    @next_path = "#{path}?#{ { before: @events.last.id }.to_query }" if records.length > 50
  end

  def security_audit_action
    "security_audit.view"
  end
end
