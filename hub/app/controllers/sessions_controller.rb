# Revokes authenticated browser sessions.
class SessionsController < ApplicationController
  # @route DELETE /session (session)
  def destroy
    terminate_session
    redirect_to root_path
  end
end
