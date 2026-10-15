# Creates public links through a repository-scoped canvas grant.
class CanvasApi::ShareLinksController < CanvasApi::BaseController
  include HasShareLinkContext

  before_action :load_share_link_prototype
  before_action :require_public_sharing

  rescue_from ShareLink::InvalidExpiration, ActiveRecord::RecordInvalid, with: :invalid_share_link
  rescue_from ActiveRecord::RecordNotFound, with: :share_link_target_not_found
  rescue_from ShareLink::InvalidPagination, with: :invalid_pagination
  rescue_from SharingSetting::Disabled, SharingSetting::Changed, with: :public_sharing_disabled
  rescue_from ShareLinkCreatorRevocation::Changed, with: :creator_access_changed

  # @route GET /api/canvas/repositories/:repository_github_id/prototypes/:prototype_id/share_links (canvas_api_share_links)
  def index
    page = ShareLink.page_for(@prototype, cursor: params[:cursor])
    render json: {
      shareLinks: page.records.map do |link|
        share_link_json(link).merge(
          createdAt: link.created_at.iso8601,
          createdBy: { login: link.created_by.login, name: link.created_by.name }
        )
      end,
      hasMore: page.has_more,
      nextCursor: page.next_cursor
    }
  end

  # @route POST /api/canvas/repositories/:repository_github_id/prototypes/:prototype_id/share_links (canvas_api_share_links)
  def create
    share_link = create_share_link
    return if performed?

    render \
      json: share_link_json(share_link),
      status: :created
  end

  # @route DELETE /api/canvas/repositories/:repository_github_id/prototypes/:prototype_id/share_links/:id (canvas_api_share_link)
  def destroy
    link = @prototype.share_links.find_by(id: params[:id])
    unless link
      render \
        json: { errors: [ "The share link was not found. Refresh links to see the active list." ] },
        status: :not_found
      return
    end

    link.destroy!
    head :no_content
  end

  private

  def require_public_sharing
    public_sharing_disabled if !SharingSetting.enabled?
  end

  def security_audit_action
    { "create" => "share_link.create", "destroy" => "share_link.delete" }[action_name]
  end

  def share_link_json(link)
    {
      id: link.id,
      url: "#{Rails.configuration.x.hub_origin.delete_suffix('/')}#{shared_build_path(link.public_id)}",
      buildNumber: link.build.number,
      label: link.label,
      expiresAt: link.effective_expires_at&.iso8601
    }
  end

  def invalid_pagination
    render json: { errors: [ "The share-link page cursor is invalid." ] }, status: :bad_request
  end

  def invalid_share_link(error)
    record_security_audit(outcome: "failed")
    render json: { errors: share_link_errors(error) }, status: :unprocessable_entity
  end

  def share_link_target_not_found
    render json: { errors: [ "The requested Prototype or successful Build was not found." ] },
      status: :not_found
  end
end
