# Lets a repository administrator ask Hub to look for learnings now instead of waiting a day.
class LearningRunsController < SuperglueController
  include HasLearningWorkspace

  rescue_from GithubClient::Error, with: -> { head :service_unavailable }

  # @route POST /repositories/:repository_github_id/learnings/runs (repository_learnings_runs)
  def create
    load_learning_workspace
    return if performed?

    if !LocalDevelopment.enabled? && !CopilotConnection.current&.usable?
      record_security_audit(outcome: "denied")
      return back(alert: t("learnings.runs.copilot_refused"))
    end

    Learning::Run.transaction do
      Learning::Run.request!(repository: @repository, user: Current.user)
      record_security_audit(outcome: "succeeded")
    end
    back(notice: t("learnings.runs.requested"))
  end

  private

  def security_audit_action
    "learning.run"
  end

  def back(**flash)
    redirect_to repository_learnings_path(@repository.route_id), status: :see_other, **flash
  end
end
