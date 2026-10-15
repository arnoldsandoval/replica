# Loads a repository whose learnings its administrators can see and decide on.
module HasLearningWorkspace
  extend ActiveSupport::Concern
  include HasRepositoryWorkspace

  private

  # Responds 404 unless Learnings is on and the user currently administers the repository.
  def load_learning_workspace
    load_repository_workspace(fresh: true)
    return if performed?
    return head :not_found if !Learning.available_for?(@repository)

    head :not_found if !@repository.authorization.sufficient?(@repository_permission, minimum: :admin)
  end
end
