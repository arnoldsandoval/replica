# Announces that one authorized Prototype's review data changed.
class ReviewCommentsChannel < ApplicationCable::Channel
  periodically :verify_connection_access, every: 1.minute

  # Checks repository access before streaming change notices for one Prototype.
  def subscribed
    return reject if !connection.credential_active?

    repository = Repository.find_by_route_id! \
      positive_identifier(params[:repositoryId] || params[:repositoryGithubId])
    return reject if connection.canvas_grant_id &&
      CanvasGrant.authenticated.where(id: connection.canvas_grant_id, repository:).none?

    configuration = GithubAppConfiguration.current
    return reject if !repository.authorization.authorized?(current_user, configuration:)
    return reject if !connection.credential_active?

    prototype = repository.reviewable_prototypes.find(positive_identifier(params[:prototypeId]))
    stream_for prototype, method(:transmit_review_notice), coder: ActiveSupport::JSON
  rescue ActiveRecord::RecordNotFound, GithubClient::Error
    reject
  end

  class << self
    # Tells authorized subscribers to reload review data through the HTTP API.
    def broadcast_invalidation(prototype)
      broadcast_to prototype, { type: "review_comments_changed" }
    end
  end

  private

  # A notice queued before revocation must not reach an ended connection.
  def transmit_review_notice(message)
    if connection.credential_active?
      transmit message
    else
      connection.close
    end
  end

  # Live traffic never extends a canvas connection or substitutes for fresh access.
  def verify_connection_access
    return connection.close if !connection.credential_active?
    return if !connection.canvas_grant_id

    grant = CanvasGrant.authenticated.find_by(id: connection.canvas_grant_id)
    return if grant && grant.repository.authorization.authorized?(current_user, fresh: true) &&
      connection.credential_active?

    connection.close
  rescue GithubClient::Error
    connection.close
  end

  # Accepts only positive integer identifiers from the subscription request.
  def positive_identifier(value)
    raise ActiveRecord::RecordNotFound if !value.is_a?(Integer) || !value.positive?

    value
  end
end
