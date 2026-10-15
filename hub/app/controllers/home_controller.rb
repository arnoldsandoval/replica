# Renders the public application entry point.
class HomeController < SuperglueController
  allow_unauthenticated_access

  # @route GET / (root)
  def index
    resume_session
    if authenticated?
      flash.keep(:notice)
      redirect_to repositories_path
    end
  end
end
