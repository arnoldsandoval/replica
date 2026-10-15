# Shares suggestions without sharing browser and bearer-token authentication.
module MentionCandidates
  extend ActiveSupport::Concern

  included do
    include HasReviewCommentContext
    before_action { response.headers["Cache-Control"] = "private, no-store" }
  end

  def index
    return render json: { candidates: [] } if @repository.local?

    configuration = GithubAppConfiguration.current
    candidates = Rails.cache.fetch \
      [ "mention-candidates", @repository.cache_key_with_version ],
      expires_in: 1.minute do
      configuration.github_client.repositories.mention_candidates \
        @repository,
        token: configuration.tokens.installation
    end
    render json: { candidates: candidates }
  end
end
