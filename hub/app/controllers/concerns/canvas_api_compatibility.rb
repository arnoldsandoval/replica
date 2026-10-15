# Lets compatible plugin and Hub releases communicate without matching release numbers.
module CanvasApiCompatibility
  extend ActiveSupport::Concern

  included do
    before_action :check_canvas_interface
  end

  private

  def check_canvas_interface
    response.headers["X-Replica-Canvas-Version"] = "1"
    version = request.headers["X-Replica-Canvas-Version"]
    return if version.blank? || version == "1"

    render json: {
      code: "incompatible_canvas_interface",
      error: "This plugin and Hub do not support the same Canvas interface. Update to compatible releases."
    }, status: :conflict
  end
end
