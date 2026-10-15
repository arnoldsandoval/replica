# Serves controls transport without review commands or viewer information.
module PreviewControlsRespondable
  extend ActiveSupport::Concern

  CONTROLS_TAG = "\n<script src=\"/__replica/controls/v1.js\"></script>\n"
  CONTROLS_ORIGIN_PLACEHOLDER = /(["'`])__REPLICA_CONTROLS_PARENT_ORIGIN__\1/

  # Serves the injected Controls bridge after existing preview authorization.
  # @route GET /__replica/preview/controls
  # @route GET /__replica/share/controls
  def controls
    source = File.binread(Rails.root.join("app/javascript/features/install-replica-controls-bridge/bridge.js"))
    raise "Controls bridge origin placeholder is missing" if !source.match?(CONTROLS_ORIGIN_PLACEHOLDER)

    source = source.sub(CONTROLS_ORIGIN_PLACEHOLDER) do
      Rails.configuration.x.hub_origin.delete_suffix("/").to_json
    end
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
    render body: source, content_type: "text/javascript; charset=utf-8"
  end
end
