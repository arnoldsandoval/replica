class CanvasApi::ReviewCommentSummariesController < CanvasApi::BaseController
  include ReviewCommentPages

  RESPONSE_MAXIMUM_BYTES = 60 * 1024

  rescue_from ReviewComment::ResponseTooLarge, with: -> { head :content_too_large }

  # @route GET /api/canvas/repositories/:repository_github_id/review_comment_summaries (canvas_api_repository_review_comment_summaries)
  def index
    filters = summary_filters
    page = ReviewComment.summary_page_for_repository \
      @repository,
      viewer: Current.user,
      cursor: pagination_cursor,
      page_size: page_size,
      filters: do |candidate|
        summary_page_json(candidate).to_json.bytesize <= RESPONSE_MAXIMUM_BYTES
      end
    render json: summary_page_json(page)
  end

  private

  def summary_filters
    resolution = params[:resolution] || "all"
    raise ReviewComment::InvalidPagination if !%w[all unresolved resolved].include?(resolution)

    dates = %i[from to].to_h do |key|
      value = params[key]
      if value
        raise ReviewComment::InvalidPagination if !value.is_a?(String) ||
          !value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})\z/)

        Date.iso8601(value[0, 10])
        value = Time.iso8601(value)
      end
      [ key, value ]
    end
    raise ReviewComment::InvalidPagination if dates[:from] && dates[:to] && dates[:from] >= dates[:to]

    dates.merge(resolution:)
  rescue ArgumentError
    raise ReviewComment::InvalidPagination
  end

  def summary_page_json(page)
    @reply_counts ||= ReviewComment.not_deleted.where(root_id: page.records.map(&:id)).group(:root_id).count
    {
      comments: page.records.map do |comment|
        prototype = comment.prototype
        anchor = comment.anchor
        {
          id: comment.id,
          body: comment.body,
          authorLogin: comment.user.login,
          createdAt: comment.created_at.iso8601(6),
          editedAt: comment.edited_at&.iso8601(6),
          prototype: { id: prototype.id, name: prototype.name, branch: prototype.branch_name },
          buildNumber: comment.build.number,
          buildPath: repository_prototype_path(@repository.route_id, prototype, build: comment.build.number),
          resolvedAt: comment.resolved_at&.iso8601(6),
          replyCount: @reply_counts.fetch(comment.id, 0),
          targetContext: anchor.slice("kind", "route", "accessibleName", "tagName", "selectedText").merge(
            anchor["kind"] == "area" ? {
              "elements" => anchor.fetch("elements").map { _1.slice("accessibleName", "tagName", "role", "textExcerpt") }
            } : {}
          ),
          screenshotReference: nil
        }
      end,
      nextCursor: page.next_cursor,
      hasMore: page.has_more
    }
  end
end
