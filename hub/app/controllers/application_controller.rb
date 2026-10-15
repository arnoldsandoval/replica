class ApplicationController < ActionController::Base
  include Authentication
  include SecurityAuditing
  include SecurityRateLimiting
  include HasRepositoryWorkspace
  before_action :limit_hub_admin_mutation

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern
end
