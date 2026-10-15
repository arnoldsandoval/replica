# Exchanges an authenticated API request for a short-lived WebSocket handshake.
class CanvasApi::CableTicketsController < CanvasApi::BaseController
  # @route POST /api/canvas/cable_ticket (canvas_api_cable_ticket)
  def create
    signed = Rails.application.message_verifier("canvas-cable").generate \
      Current.canvas_grant.id,
      purpose: "canvas-cable",
      expires_in: 30.seconds
    ticket = Base64.urlsafe_encode64(signed, padding: false)
    origin = Rails.configuration.x.hub_origin.delete_suffix("/")
    cable_url = "#{origin.sub(/\Ahttp/, 'ws')}/cable"
    render json: { cableUrl: cable_url, protocol: "replica-canvas.#{ticket}" }
  end
end
