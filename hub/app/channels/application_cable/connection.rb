module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :credential_identity
    attr_reader :canvas_grant_id, :browser_session_id

    # Looks up the signed-in user from the current Hub session.
    def connect
      ticket = request.headers["Sec-WebSocket-Protocol"].to_s.split(",").map(&:strip)
        .find { _1.start_with?("replica-canvas.") }
      return connect_canvas(ticket) if ticket

      browser_session = Session.includes(:user).find_by \
        id: request.session[:authenticated_session_id]
      self.current_user = browser_session&.user if browser_session&.user&.local? == LocalDevelopment.enabled?
      reject_unauthorized_connection if current_user.nil?
      @browser_session_id = browser_session.id
      self.credential_identity = browser_session.to_gid_param
      reject_unauthorized_connection if !credential_active?
    end

    # Sees committed revocation instead of reusing an earlier request's result.
    def credential_active?
      ApplicationRecord.uncached do
        if canvas_grant_id
          CanvasGrant.authenticated.where(id: canvas_grant_id, user_id: current_user.id).exists?
        else
          Session.where(id: browser_session_id, user_id: current_user.id).exists?
        end
      end
    end

    private

    # Node has no browser Origin; only an unexpired signed canvas ticket may omit it.
    def allow_request_origin?
      return super if request.headers["Origin"].present?

      ticket = request.headers["Sec-WebSocket-Protocol"].to_s.split(",").map(&:strip)
        .find { _1.start_with?("replica-canvas.") }
      if ticket
        signed = Base64.urlsafe_decode64(ticket.delete_prefix("replica-canvas."))
        id = Rails.application.message_verifier("canvas-cable").verified \
          signed,
          purpose: "canvas-cable"
        return true if id.is_a?(Integer) && CanvasGrant.authenticated.where(id:).exists?
      end
      super
    rescue ArgumentError
      super
    end

    # The one-use API credential is never sent in a WebSocket URL.
    def connect_canvas(protocol)
      signed = Base64.urlsafe_decode64(protocol.delete_prefix("replica-canvas."))
      id = Rails.application.message_verifier("canvas-cable").verified \
        signed,
        purpose: "canvas-cable"
      grant = CanvasGrant.authenticated.where(id:).includes(:user, :repository).first
      permission = grant&.repository&.authorization&.permission_for(grant.user, fresh: true)
      allowed = grant && grant.repository.authorization.sufficient?(permission, minimum: :read)
      reject_unauthorized_connection if !allowed

      self.current_user = grant.user
      @canvas_grant_id = grant.id
      self.credential_identity = grant.to_gid_param
      reject_unauthorized_connection if !credential_active?
    rescue ArgumentError, GithubClient::Error
      reject_unauthorized_connection
    end
  end
end
