# Serves retained Build files with shared browser routing and response rules.
module PreviewFileRespondable
  extend ActiveSupport::Concern

  CONTENT_TYPES_WITH_CHARSET = {
    ".css" => "text/css; charset=utf-8",
    ".html" => "text/html; charset=utf-8",
    ".js" => "text/javascript; charset=utf-8",
    ".json" => "application/json; charset=utf-8",
    ".map" => "application/json; charset=utf-8",
    ".txt" => "text/plain; charset=utf-8"
  }.freeze

  included do
    include ArtifactRespondable
    # Build scripts must load as ordinary browser scripts, not only XHR.
    skip_after_action :verify_same_origin_request
    before_action :set_preview_headers
  end

  private

  # Serves one Build file or its HTML entry point for a browser route.
  def serve_preview_file(build, html_append: nil)
    path = requested_file
    content_type = content_type_for(path)
    append = html_append if html_append && content_type.start_with?("text/html")
    send_artifact \
      "#{build.artifact_prefix}/dist/#{path}",
      content_type:,
      missing: :raise,
      resource_policy: document_request? ? nil : "same-origin",
      append:
  rescue ArtifactStore::Missing, ArtifactStore::InvalidName => error
    return head :not_found if !document_request?
    return head :not_found if error.is_a?(ArtifactStore::InvalidName) && !safe_document_route?(path)

    send_artifact \
      "#{build.artifact_prefix}/dist/index.html",
      content_type: "text/html; charset=utf-8",
      resource_policy: nil,
      append: html_append
  end

  # Allows local browser routes without making invalid storage names readable.
  def safe_document_route?(path)
    PreviewGrant.validate_return_path(request.get_header(PreviewPathRouting::ORIGINAL_PATH))
    path.valid_encoding? && !path.start_with?("/") && !path.match?(/[[:cntrl:]\\]/) &&
      !path.split("/").intersect?([ ".", "..", ArtifactStore::INTERNAL_SEGMENT ])
  rescue ArgumentError
    false
  end

  # Applies the framing and privacy rules shared by preview responses.
  def set_preview_headers
    response.headers.delete("X-Frame-Options")
    response.headers["Content-Security-Policy"] =
      "frame-ancestors #{Rails.configuration.x.hub_origin.delete_suffix("/")}; worker-src blob:"
    response.headers["Referrer-Policy"] = "no-referrer"
  end

  # Returns the positive Build ID encoded in the request host.
  def preview_build_id
    request.get_header(PreviewPathRouting::BUILD_ID)
  end

  # Returns the requested relative Build path, with root mapped to index.html.
  def requested_file
    encoded_path = request.get_header(PreviewPathRouting::ORIGINAL_PATH)
    URI::DEFAULT_PARSER.unescape(encoded_path).delete_prefix("/").presence || "index.html"
  end

  # Reports whether a missing path is a browser document navigation.
  def document_request?
    destination = request.headers["Sec-Fetch-Dest"]
    mode = request.headers["Sec-Fetch-Mode"]
    return true if mode == "navigate"
    return %w[document iframe].include?(destination) if destination.present?

    request.accepts.first == Mime[:html]
  end

  # Returns a safe response type based on the retained file extension.
  def content_type_for(path)
    return "application/octet-stream" if !path.valid_encoding?

    extension = File.extname(path).downcase
    CONTENT_TYPES_WITH_CHARSET.fetch(extension) do
      Rack::Mime.mime_type(extension, "application/octet-stream")
    end
  end
end
