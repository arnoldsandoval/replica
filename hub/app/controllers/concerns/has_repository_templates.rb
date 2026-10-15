module HasRepositoryTemplates
  extend ActiveSupport::Concern

  include HasRepositoryWorkspace

  private

  # Captures one authorized Build for template metadata, screenshots, and routes.
  def load_repository_templates
    load_repository_workspace
    return if performed?

    owner = @repository.replica_build_owner
    @latest_build = owner&.current_build || owner&.builds&.chronological&.first
    @selected_build = owner&.builds&.where(state: "successful")&.chronological&.first
    @templates = @selected_build ? @selected_build.templates.entries : []
  end
end
