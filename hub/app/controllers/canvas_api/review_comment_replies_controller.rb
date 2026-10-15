# Adds replies to existing Hub conversations, never a new local anchor.
class CanvasApi::ReviewCommentRepliesController < CanvasApi::BaseController
  include HasReviewCommentContext
  include ReviewCommentMutations

  prepend_before_action :reject_large_request

  # @route POST /api/canvas/repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/replies (canvas_api_review_comment_replies)
  def create
    root = @prototype.review_comments.roots.find(params[:review_comment_id])
    reply = root.thread.create_reply! user: Current.user, body: comment_body
    render_review_comment_change reply, status: :created
  end
end
