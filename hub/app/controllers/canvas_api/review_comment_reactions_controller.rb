# Uses the same thread reaction rules for paired canvas reviewers.
class CanvasApi::ReviewCommentReactionsController < CanvasApi::BaseController
  include HasReviewCommentContext
  include ReviewCommentMutations

  prepend_before_action :reject_large_request

  # @route POST /api/canvas/repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/reactions (canvas_api_review_comment_reactions)
  def create
    attributes = reaction_attributes
    comment = @prototype.review_comments.not_deleted.find(params[:review_comment_id])
    comment.thread.add_reaction! \
      user: Current.user,
      content: attributes[:content],
      activity_version: positive_activity_version(attributes[:activity_version])
    render_review_comment_change comment, status: :created
  end

  # @route DELETE /api/canvas/repositories/:repository_github_id/prototypes/:prototype_id/review_comments/:review_comment_id/reactions/:content (canvas_api_review_comment_reaction)
  def destroy
    attributes = reaction_attributes
    comment = @prototype.review_comments.find(params[:review_comment_id])
    comment.thread.remove_reaction! \
      user: Current.user,
      content: params[:content],
      activity_version: positive_activity_version(attributes[:activity_version])
    render_review_comment_change comment
  end

  private

  def reaction_attributes
    params.require(:review_comment_reaction).permit(:content, :activity_version)
  end
end
