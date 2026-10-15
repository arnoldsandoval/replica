# Comment writes share one user budget; reading and marking read do not spend it.
module ReviewCommentMutations
  extend ActiveSupport::Concern

  included do
    before_action -> { enforce_security_rate_limit(:comments) },
      if: -> { action_name.in?(%w[create update destroy]) }
  end
end
