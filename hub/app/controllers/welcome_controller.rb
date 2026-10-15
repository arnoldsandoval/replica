class WelcomeController < SuperglueController
  include HasRepositoryWorkspace

  # @route GET /welcome (welcome)
  def show
  end

  # @route PATCH /welcome (welcome)
  # @route PUT /welcome (welcome)
  def update
    Current.user.hide_welcome!
    repository = hub_repository_workspace.fetch(:repository)
    redirect_to welcome_path(repository_github_id: repository&.route_id),
      notice: t("welcome.hidden"), status: :see_other
  end
end
