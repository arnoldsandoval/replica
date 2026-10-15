require "test_helper"
require "tmpdir"

class PreviewsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_artifact_store = Rails.configuration.x.artifact_store
    @previous_artifact_root = Rails.configuration.x.artifact_root
    @artifact_root = Pathname(Dir.mktmpdir("replica-preview-"))
    Rails.configuration.x.artifact_store = "local"
    Rails.configuration.x.artifact_root = @artifact_root
    host! "replica.localhost:19500"
    github_app_configurations.create_installed
    @repository_payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ @repository_payload ], permissions: { 2001 => "pull" })
    sign_in
    @repository = Repository.find_by!(github_id: 2001)
    @prototype = prototypes.create(repository: @repository, branch_name: "prototype/welcome")
    @build = builds.create_successful(prototype: @prototype)
    write_build_files(@build)
  end

  teardown do
    Rails.configuration.x.artifact_store = @previous_artifact_store
    Rails.configuration.x.artifact_root = @previous_artifact_root
    FileUtils.rm_rf(@artifact_root)
  end

  test "opens the saved start page in review and standalone previews while explicit routes take precedence" do
    @prototype.update!(start_page: "/settings?tab=profile#details")
    get repository_prototype_path(@repository.route_id, @prototype), as: :json
    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert_equal "#{PreviewOrigin.current.url(@build.id)}settings?tab=profile#details",
      data.fetch("selectedBuild").fetch("previewUrl")

    get repository_prototype_path(@repository.route_id, @prototype, return_path: "/specific#comment"), as: :json
    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert_equal "#{PreviewOrigin.current.url(@build.id)}specific#comment",
      data.fetch("selectedBuild").fetch("previewUrl")

    [ [ nil, "/settings?tab=profile#details" ], [ "/specific?q=1#comment", "/specific?q=1#comment" ],
      [ "/", "/" ] ].each do |return_path, expected|
      host! "replica.localhost:19500"
      get preview_build_authorization_path(@build.id), params: { return_path: }
      assert_response :redirect
      grant = Rack::Utils.parse_query(URI(response.location).query).fetch("grant")
      host! "b#{@build.id}.preview.replica.localhost:19500"
      get "/__replica/authorize", params: { grant: }
      assert_redirected_to expected
    end
  end

  test "uses current start-page metadata when opening an older Build" do
    builds.create_successful(prototype: @prototype, number: 2, commit_sha: "b" * 40)
    @prototype.update!(start_page: "/new-entry")
    get repository_prototype_path(@repository.route_id, @prototype, build: @build.number), as: :json
    assert_response :success
    assert_equal "#{PreviewOrigin.current.url(@build.id)}new-entry",
      JSON.parse(response.body).fetch("data").fetch("selectedBuild").fetch("previewUrl")
  end

  test "reopens a minimized Hub link at its exact Build, route, query and fragment" do
    builds.create_successful(prototype: @prototype, number: 2, commit_sha: "b" * 40)
    @prototype.update!(start_page: "/copilot")
    route = "/copilot/task/123?tab=activity#/details"

    path = repository_prototype_path \
      @repository.route_id,
      @prototype,
      build: @build.number,
      return_path: route,
      view: "minimized"
    get path, as: :json

    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert_equal @build.number, data.fetch("selectedBuild").fetch("number")
    assert_equal "#{PreviewOrigin.current.url(@build.id)}#{route.delete_prefix('/')}",
      data.fetch("selectedBuild").fetch("previewUrl")
    assert_equal true, data.fetch("minimizedPreview")
    assert_equal "Minimize Hub UI", data.fetch("minimizeHubLabel")
    assert_equal "Maximize Hub UI", data.fetch("maximizeHubLabel")
    assert_equal "Copy prototype link", data.fetch("copyPreviewUrlLabel")
  end

  test "default Builds open at root and keep the existing session and read-access boundary" do
    @prototype.update!(start_page: "/old-prototype-route")
    @repository.update!(default_branch: @prototype.branch_name)
    get preview_build_authorization_path(@build.id)
    assert_response :redirect
    grant = Rack::Utils.parse_query(URI(response.location).query).fetch("grant")
    host! "b#{@build.id}.preview.replica.localhost:19500"
    get "/__replica/authorize", params: { grant: }
    assert_redirected_to "/"
    get "/"
    assert_response :success
    assert_includes response.body, "Preview"

    Rails.cache.clear
    stub_github_permissions([ @repository_payload ], { 2001 => nil })
    get "/"
    assert_response :not_found
    host! "replica.localhost:19500"
    get preview_build_authorization_path(@build.id)
    assert_response :not_found
  end

  test "rejects external review destinations" do
    get repository_prototype_path(@repository.route_id, @prototype, return_path: "//example.com")
    assert_response :not_found
  end

  test "authorizes a successful Build and serves its root and assets" do
    get repository_prototype_path(@repository.route_id, @prototype)
    assert_response :success
    nonce = css_select("meta[name='csp-nonce']").first["content"]
    assert_equal \
      HubContentSecurityPolicy.build(development: false).build(Object.new, nonce, %w[script-src]),
      response.headers["Content-Security-Policy"]
    assert_select "script[nonce]", text: /SUPERGLUE_INITIAL_PAGE_STATE=/

    get preview_build_authorization_path(@build.id)

    assert_response :redirect
    grant = Rack::Utils.parse_query(URI(response.location).query).fetch("grant")
    host! "b#{@build.id}.preview.replica.localhost:19500"
    get "/__replica/authorize", params: { grant: }
    assert_redirected_to "/"
    assert_match(/replica_preview=/, response.headers.fetch("Set-Cookie"))
    assert_match(/httponly/i, response.headers.fetch("Set-Cookie"))
    assert_match(/samesite=lax/i, response.headers.fetch("Set-Cookie"))
    refute_match(/;\s*domain=/i, response.headers.fetch("Set-Cookie"))
    assert_not_includes response.headers.fetch("Set-Cookie"), "#{LocalDevelopment.session_cookie_key}="
    assert_equal "no-referrer", response.headers["Referrer-Policy"]

    get "/"
    assert_response :success
    assert_equal "text/html", response.media_type
    assert_equal "utf-8", response.charset
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_nil response.headers["X-Frame-Options"]
    assert_equal \
      "frame-ancestors http://replica.localhost:19500; worker-src blob:",
      response.headers["Content-Security-Policy"]
    assert_nil response.headers["Content-Security-Policy-Report-Only"]
    assert_not_includes response.body, "SUPERGLUE_INITIAL_PAGE_STATE"
    assert_select "meta[name='csp-nonce']", count: 0
    assert_nil response.headers["Cross-Origin-Resource-Policy"]
    assert_includes response.body, "Preview"
    assert_includes response.body, PreviewFilesController::BRIDGE_TAG.strip
    assert_includes response.body, PreviewControlsRespondable::CONTROLS_TAG.strip

    get PreviewPathRouting::PUBLIC_CONTROLS_PATH,
      headers: { "HTTP_ACCEPT" => "*/*", "HTTP_SEC_FETCH_DEST" => "script" }
    assert_response :success
    assert_equal "text/javascript", response.media_type
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "same-origin", response.headers["Cross-Origin-Resource-Policy"]
    assert_includes response.body, '"http://replica.localhost:19500"'
    assert_not_includes response.body, "__REPLICA_CONTROLS_PARENT_ORIGIN__"

    get PreviewPathRouting::PUBLIC_BRIDGE_PATH,
      headers: { "HTTP_ACCEPT" => "*/*", "HTTP_SEC_FETCH_DEST" => "script" }
    assert_response :success
    assert_equal "text/javascript", response.media_type
    assert_equal "utf-8", response.charset
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "same-origin", response.headers["Cross-Origin-Resource-Policy"]
    assert_includes response.body, 'const HUB_ORIGIN = "http://replica.localhost:19500"'
    assert_not_includes response.body, "__REPLICA_HUB_ORIGIN__"

    get "/assets/app.js", headers: { "HTTP_ACCEPT" => "*/*", "HTTP_SEC_FETCH_DEST" => "script" }
    assert_response :success
    assert_equal "text/javascript; charset=utf-8", response.headers["Content-Type"]
    assert_equal "same-origin", response.headers["Cross-Origin-Resource-Policy"]
    assert_equal "console.log('preview')", response.body
  end

  test "redirects an unauthenticated preview request through Hub" do
    reset!
    host! "b#{@build.id}.preview.replica.localhost:19500"

    get "/settings?tab=general", headers: { "HTTP_ACCEPT" => "text/html" }

    expected = "http://replica.localhost:19500#{preview_build_authorization_path(@build.id, return_path: "/settings?tab=general")}"
    assert_redirected_to expected
  end

  test "controls files require a current authorized preview and stop after sign-out" do
    authorize_preview
    get PreviewPathRouting::PUBLIC_CONTROLS_PATH
    assert_response :success
    Session.delete_all
    get PreviewPathRouting::PUBLIC_CONTROLS_PATH
    assert_response :redirect
  end

  test "deployment revocation ends preview cookies and cancels unused signed-in handoffs" do
    actor = User.find_by!(github_id: 1001)
    actor.update!(hub_admin: true)
    browser_session = actor.sessions.sole
    authorize_preview
    get "/"
    assert_response :success
    unused = PreviewGrant.issue!(build: @build, session: browser_session, return_path: "/")

    SessionRevocation.end_all!(actor:, browser_session:)

    [ "/", "/assets/app.js", PreviewPathRouting::PUBLIC_BRIDGE_PATH,
      PreviewPathRouting::PUBLIC_CONTROLS_PATH ].each do |path|
      get path
      assert_response :redirect
    end
    get "/__replica/authorize", params: { grant: unused }
    assert_response :not_found
    host! "replica.localhost:19500"
    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
    assert_redirected_to repositories_path
    host! "b#{@build.id}.preview.replica.localhost:19500"
    get "/"
    assert_response :redirect
  end

  test "a private preview waiting on GitHub denies access after the cutoff" do
    actor = User.find_by!(github_id: 1001)
    actor.update!(hub_admin: true)
    browser_session = actor.sessions.sole
    authorize_preview
    Rails.cache.clear
    stub_request(:get, "#{GITHUB_API_URL}/repos/github/prototype/collaborators/octocat/permission").to_return do
      SessionRevocation.end_all!(actor:, browser_session:)
      { status: 200, body: { permission: "pull", user: { id: actor.github_id } }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end

    get "/"

    assert_response :not_found
    assert_empty response.body
    assert_empty Session.all
  end

  test "controls storage identity is stable across Builds but includes viewer and prototype" do
    get repository_prototype_path(@repository.route_id, @prototype), as: :json
    identity = JSON.parse(response.body).fetch("data").fetch("controlsIdentity")
    assert_match(/\A[0-9a-f]{64}\z/, identity)
    builds.create_successful(prototype: @prototype, number: 2, commit_sha: "b" * 40)
    get repository_prototype_path(@repository.route_id, @prototype), as: :json
    assert_equal identity, JSON.parse(response.body).fetch("data").fetch("controlsIdentity")
    helper = Object.new.extend(PreviewControlsHelper)
    assert_not_equal helper.preview_controls_identity(@prototype, context: [ "authenticated", 1 ]),
      helper.preview_controls_identity(@prototype, context: [ "authenticated", 2 ])
    assert_not_equal helper.preview_controls_identity(@prototype, context: [ "authenticated", 1 ]),
      helper.preview_controls_identity(@prototype, context: [ "public", "share" ])
  end

  test "a GitHub preview cookie does not resume in local mode" do
    authorize_preview
    assert_match(/replica_preview=/, response.headers.fetch("Set-Cookie"))

    original_enabled = LocalDevelopment.method(:enabled?)
    LocalDevelopment.define_singleton_method(:enabled?) { true }
    get "/"

    assert_redirected_to \
      "http://replica.localhost:19500#{preview_build_authorization_path(@build.id, return_path: "/")}"
    assert_equal :replica_local_preview, PreviewFilesController.new.send(:preview_cookie_name)
  ensure
    LocalDevelopment.define_singleton_method(:enabled?, original_enabled) if original_enabled
  end

  test "does not reveal Build state before preview authentication" do
    reset!
    missing_build_id = @build.id + 1
    host! "b#{missing_build_id}.preview.replica.localhost:19500"

    get "/"

    assert_redirected_to \
      "http://replica.localhost:19500#{preview_build_authorization_path(missing_build_id, return_path: "/")}"
  end

  test "falls back to index only for document navigation" do
    authorize_preview

    get "/settings", headers: { "HTTP_ACCEPT" => "text/html", "HTTP_SEC_FETCH_DEST" => "document" }
    assert_response :success
    assert_includes response.body, "Preview"

    get "/assets/missing.js", headers: { "HTTP_ACCEPT" => "*/*", "HTTP_SEC_FETCH_DEST" => "script" }
    assert_response :not_found
  end

  test "serves encoded file names and iframe routes" do
    ArtifactStore.current.write \
      "#{@build.artifact_prefix}/dist/assets/app file.js",
      source: StringIO.new("console.log('space')")
    authorize_preview

    get "/assets/app%20file.js", headers: { "HTTP_ACCEPT" => "*/*", "HTTP_SEC_FETCH_DEST" => "script" }
    assert_response :success
    assert_equal "console.log('space')", response.body

    get "/settings", headers: { "HTTP_ACCEPT" => "text/html", "HTTP_SEC_FETCH_DEST" => "iframe" }
    assert_response :success
    assert_includes response.body, "Preview"
  end

  test "serves document routes that cannot be artifact names without weakening asset restrictions" do
    authorize_preview

    [ "/caf%C3%A9/v2.0", "/docs/", "/a//b", "/#{'a' * 300}", "/#{'a' * 1100}",
      "/#{'nested/' * 24}page" ].each do |path|
      get path, headers: { "HTTP_ACCEPT" => "text/html", "HTTP_SEC_FETCH_DEST" => "iframe" }
      assert_response :success, path
      assert_includes response.body, "Preview"
      assert_includes response.body, PreviewFilesController::BRIDGE_TAG.strip
    end

    [ "/caf%C3%A9.png", "/docs/", "/#{'a' * 300}.js", "/%2e%2e/secret" ].each do |path|
      get path, headers: { "HTTP_ACCEPT" => "*/*", "HTTP_SEC_FETCH_DEST" => "script" }
      assert_response :not_found, path
    end

    [ "/bad%0a", "/%2e%2e/secret", "/.replica-internal/file", "/%2fexample.com" ].each do |path|
      get path, headers: { "HTTP_ACCEPT" => "text/html", "HTTP_SEC_FETCH_DEST" => "iframe" }
      assert_response :not_found, path
    end
    get "/%ff", headers: { "HTTP_ACCEPT" => "*/*", "HTTP_SEC_FETCH_DEST" => "script" }
    assert_response :bad_request
  end

  test "appends the bridge without changing retained nested HTML" do
    source = <<~HTML
      <!doctype html>
      <script>window.template = "</head><body>About</body>"</script>
    HTML
    ArtifactStore.current.write \
      "#{@build.artifact_prefix}/dist/about.html",
      source: StringIO.new(source)
    authorize_preview

    get "/about.html", headers: { "HTTP_ACCEPT" => "text/html", "HTTP_SEC_FETCH_DEST" => "iframe" }

    assert_response :success
    assert_equal source + PreviewFilesController::BRIDGE_TAG + PreviewControlsRespondable::CONTROLS_TAG,
      response.body
  end

  test "rejects a grant on a different Build host" do
    host! "replica.localhost:19500"
    get preview_build_authorization_path(@build.id)
    grant = Rack::Utils.parse_query(URI(response.location).query).fetch("grant")
    host! "b#{@build.id + 1}.preview.replica.localhost:19500"

    get "/__replica/authorize", params: { grant: }

    assert_response :not_found
    assert_nil response.headers["Set-Cookie"]
  end

  test "accepts a preview grant only once" do
    host! "replica.localhost:19500"
    get preview_build_authorization_path(@build.id)
    grant = Rack::Utils.parse_query(URI(response.location).query).fetch("grant")
    host! "b#{@build.id}.preview.replica.localhost:19500"

    get "/__replica/authorize", params: { grant: }
    assert_redirected_to "/"
    reset!
    host! "b#{@build.id}.preview.replica.localhost:19500"
    get "/__replica/authorize", params: { grant: }

    assert_response :not_found
  end

  test "denies preview files after the browser session is revoked" do
    browser_session = Session.last
    authorize_preview
    browser_session.destroy!

    get "/"

    assert_redirected_to \
      "http://replica.localhost:19500#{preview_build_authorization_path(@build.id, return_path: "/")}"
  end

  test "denies a user who lost repository access" do
    authorize_preview
    Rails.cache.clear
    stub_github_permissions([ @repository_payload ], { 2001 => nil })

    get "/"

    assert_response :not_found
  end

  test "does not authorize an unfinished Build" do
    host! "replica.localhost:19500"
    unfinished = builds.create(prototype: @prototype, number: 2, commit_sha: "b" * 40)

    get preview_build_authorization_path(unfinished.id)

    assert_response :not_found
  end

  test "does not expose Hub routes on a preview host" do
    host! "b#{@build.id}.preview.replica.localhost:19500"

    get "/repositories"

    expected = "http://replica.localhost:19500#{preview_build_authorization_path(@build.id, return_path: "/repositories")}"
    assert_redirected_to expected
  end

  test "does not expose internal preview routes on the Hub host" do
    host! "replica.localhost:19500"

    get "/__replica/preview/files"

    assert_response :not_found
  end

  test "does not expose the internal bridge route on the Hub host" do
    host! "replica.localhost:19500"

    get "/__replica/preview/bridge"

    assert_response :not_found
  end

  test "serves retained screenshots only through an authorized Hub page" do
    host! "replica.localhost:19500"

    get repository_prototype_build_screenshot_path \
      @repository.github_id,
      @prototype,
      @build.number,
      "desktop"

    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal "desktop", response.body
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "same-origin", response.headers["Cross-Origin-Resource-Policy"]
  end

  test "serves dark screenshots with the same access checks and falls back for older Builds" do
    path = repository_prototype_build_screenshot_path \
      @repository.github_id,
      @prototype,
      @build.number,
      "desktop"
    get path, params: { theme: "dark" }
    assert_response :success
    assert_equal "desktop", response.body

    ArtifactStore.current.write \
      "#{@build.artifact_prefix}/screenshots/desktop-dark.png",
      source: StringIO.new("dark desktop")
    get path, params: { theme: "dark" }
    assert_response :success
    assert_equal "dark desktop", response.body
    assert_equal "private, no-store", response.headers["Cache-Control"]
    get path, params: { theme: "light" }
    assert_response :success
    assert_equal "desktop", response.body
    get path, params: { theme: "../dark" }
    assert_response :bad_request

    Rails.cache.clear
    stub_github_permissions([ @repository_payload ], { 2001 => nil })
    get path, params: { theme: "dark" }
    assert_response :not_found
  end

  test "reads dark screenshots directly and falls back only for missing files" do
    store = ArtifactStore.current
    original_read = store.method(:read)
    reads = []
    failure = nil
    store.define_singleton_method(:read) do |name, destination:|
      reads << name
      raise failure if failure

      original_read.call(name, destination:)
    end
    store.define_singleton_method(:exist?) { |_name| raise "Screenshots must not check existence before reading" }
    path = repository_prototype_build_screenshot_path \
      @repository.github_id,
      @prototype,
      @build.number,
      "desktop"
    light = "#{@build.artifact_prefix}/screenshots/desktop.png"
    dark = "#{@build.artifact_prefix}/screenshots/desktop-dark.png"

    get path, params: { theme: "dark" }
    assert_response :success
    assert_equal [ dark, light ], reads

    store.write(dark, source: StringIO.new("dark desktop"))
    reads.clear
    get path, params: { theme: "dark" }
    assert_response :success
    assert_equal "dark desktop", response.body
    assert_equal [ dark ], reads

    reads.clear
    failure = ArtifactStore::TemporaryError.new("Storage unavailable")
    get path, params: { theme: "dark" }
    assert_response :service_unavailable
    assert_equal [ dark ], reads
  ensure
    store.singleton_class.remove_method(:read)
    store.singleton_class.remove_method(:exist?)
  end

  test "does not serve a screenshot to a signed-out browser" do
    reset!
    host! "replica.localhost:19500"

    get repository_prototype_build_screenshot_path \
      @repository.github_id,
      @prototype,
      @build.number,
      "desktop"

    assert_redirected_to root_path
  end

  test "OAuth returns a signed-out preview visitor to authorization" do
    reset!
    host! "b#{@build.id}.preview.replica.localhost:19500"
    get "/"
    follow_redirect!
    assert_redirected_to root_path
    follow_redirect!

    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }

    assert_redirected_to preview_build_authorization_path(@build.id, return_path: "/")
  end

  private

  def authorize_preview
    host! "replica.localhost:19500"
    get preview_build_authorization_path(@build.id)
    grant = Rack::Utils.parse_query(URI(response.location).query).fetch("grant")
    host! "b#{@build.id}.preview.replica.localhost:19500"
    get "/__replica/authorize", params: { grant: }
  end

  def write_build_files(build)
    store = ArtifactStore.current
    store.write \
      "#{build.artifact_prefix}/dist/index.html",
      source: StringIO.new("<!doctype html><title>Preview</title>")
    store.write \
      "#{build.artifact_prefix}/dist/assets/app.js",
      source: StringIO.new("console.log('preview')")
    store.write \
      "#{build.artifact_prefix}/screenshots/desktop.png",
      source: StringIO.new("desktop")
    store.write \
      "#{build.artifact_prefix}/screenshots/narrow.png",
      source: StringIO.new("narrow")
  end

  def sign_in
    sign_in_to_hub
  end
end
