# Routes preview requests to controllers instead of Hub's public files.
class PreviewPathRouting
  ORIGINAL_PATH = "replica.preview_original_path"
  BUILD_ID = "replica.preview_build_id"
  MODE = "replica.preview_mode"
  AUTHENTICATED_MODE = "authenticated"
  SHARE_MODE = "share"
  FILES_PATH = "/__replica/preview/files"
  SHARE_FILES_PATH = "/__replica/share/files"
  AUTHORIZATION_PATH = "/__replica/preview/authorize"
  SHARE_AUTHORIZATION_PATH = "/__replica/share/authorize"
  BRIDGE_PATH = "/__replica/preview/bridge"
  SHARE_NOT_FOUND_PATH = "/__replica/share/not_found"
  PUBLIC_BRIDGE_PATH = "/__replica/bridge/v1.js"
  PUBLIC_CONTROLS_PATH = "/__replica/controls/v1.js"

  def initialize(app)
    @app = app
  end

  # Maps one preview URL to an internal Rails route.
  def call(environment)
    return @app.call(environment) if environment[BUILD_ID]

    request = ActionDispatch::Request.new(environment)
    build_id = PreviewOrigin.current.build_id(request)
    mode = AUTHENTICATED_MODE
    if build_id.nil?
      build_id = SharePreviewOrigin.current.build_id(request)
      mode = SHARE_MODE
    end
    return @app.call(environment) if build_id.nil?

    environment[ORIGINAL_PATH] = request.path
    environment[BUILD_ID] = build_id
    environment[MODE] = mode
    files_path = mode == SHARE_MODE ? SHARE_FILES_PATH : FILES_PATH
    environment["PATH_INFO"] = if request.path == "/__replica/authorize"
      mode == SHARE_MODE ? SHARE_AUTHORIZATION_PATH : AUTHORIZATION_PATH
    elsif request.path == PUBLIC_BRIDGE_PATH
      mode == SHARE_MODE ? SHARE_NOT_FOUND_PATH : BRIDGE_PATH
    elsif request.path == PUBLIC_CONTROLS_PATH
      mode == SHARE_MODE ? "/__replica/share/controls" : "/__replica/preview/controls"
    elsif request.path == "/"
      files_path
    else
      "#{files_path}#{request.path}"
    end
    @app.call(environment)
  end
end
