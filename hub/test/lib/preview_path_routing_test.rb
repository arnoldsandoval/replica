require "test_helper"

class PreviewPathRoutingTest < ActiveSupport::TestCase
  test "rewrites a preview path before static files can serve it" do
    application = ->(environment) { [ 200, {}, [ environment.fetch("PATH_INFO") ] ] }
    middleware = PreviewPathRouting.new(application)
    environment = Rack::MockRequest.env_for(
      "http://b12.preview.replica.localhost:19500/assets/app.js"
    )

    _, _, body = middleware.call(environment)

    assert_equal [ "/__replica/preview/files/assets/app.js" ], body
    assert_equal "/assets/app.js", environment[PreviewPathRouting::ORIGINAL_PATH]
    assert_equal 12, environment[PreviewPathRouting::BUILD_ID]
    assert_equal PreviewPathRouting::AUTHENTICATED_MODE, environment[PreviewPathRouting::MODE]
  end

  test "does not rewrite a Hub path" do
    application = ->(environment) { [ 200, {}, [ environment.fetch("PATH_INFO") ] ] }
    middleware = PreviewPathRouting.new(application)
    environment = Rack::MockRequest.env_for("http://replica.localhost:19500/repositories")

    _, _, body = middleware.call(environment)

    assert_equal [ "/repositories" ], body
    assert_nil environment[PreviewPathRouting::ORIGINAL_PATH]
  end

  test "does not rewrite a preview request twice" do
    application = ->(environment) { [ 200, {}, [ environment.fetch("PATH_INFO") ] ] }
    middleware = PreviewPathRouting.new(application)
    environment = Rack::MockRequest.env_for(
      "http://b12.preview.replica.localhost:19500/__replica/preview/files"
    )
    environment[PreviewPathRouting::BUILD_ID] = 12

    _, _, body = middleware.call(environment)

    assert_equal [ "/__replica/preview/files" ], body
  end

  test "routes the fixed bridge before retained Build files" do
    application = ->(environment) { [ 200, {}, [ environment.fetch("PATH_INFO") ] ] }
    middleware = PreviewPathRouting.new(application)
    environment = Rack::MockRequest.env_for \
      "http://b12.preview.replica.localhost:19500/__replica/bridge/v1.js"

    _, _, body = middleware.call(environment)

    assert_equal [ "/__replica/preview/bridge" ], body
    assert_equal PreviewPathRouting::PUBLIC_BRIDGE_PATH, environment[PreviewPathRouting::ORIGINAL_PATH]
  end

  test "routes a public share preview without exposing the review bridge" do
    application = ->(environment) { [ 200, {}, [ environment.fetch("PATH_INFO") ] ] }
    middleware = PreviewPathRouting.new(application)
    environment = Rack::MockRequest.env_for \
      "http://s12.preview.replica.localhost:19500/__replica/bridge/v1.js"

    _, _, body = middleware.call(environment)

    assert_equal [ PreviewPathRouting::SHARE_NOT_FOUND_PATH ], body
    assert_equal 12, environment[PreviewPathRouting::BUILD_ID]
    assert_equal PreviewPathRouting::SHARE_MODE, environment[PreviewPathRouting::MODE]
  end

  test "routes a public share authorization separately" do
    application = ->(environment) { [ 200, {}, [ environment.fetch("PATH_INFO") ] ] }
    middleware = PreviewPathRouting.new(application)
    environment = Rack::MockRequest.env_for \
      "http://s12.preview.replica.localhost:19500/__replica/authorize"

    _, _, body = middleware.call(environment)

    assert_equal [ PreviewPathRouting::SHARE_AUTHORIZATION_PATH ], body
  end

  test "routes public share files separately" do
    application = ->(environment) { [ 200, {}, [ environment.fetch("PATH_INFO") ] ] }
    middleware = PreviewPathRouting.new(application)
    environment = Rack::MockRequest.env_for \
      "http://s12.preview.replica.localhost:19500/assets/app.js"

    _, _, body = middleware.call(environment)

    assert_equal [ "#{PreviewPathRouting::SHARE_FILES_PATH}/assets/app.js" ], body
  end

  test "reserves controls transport on both authorized preview origins" do
    application = ->(environment) { [ 200, {}, [ environment.fetch("PATH_INFO") ] ] }
    middleware = PreviewPathRouting.new(application)
    { "b" => "preview", "s" => "share" }.each do |prefix, mode|
      environment = Rack::MockRequest.env_for \
        "http://#{prefix}12.preview.replica.localhost:19500/__replica/controls/v1.js"
      _, _, body = middleware.call(environment)
      assert_equal [ "/__replica/#{mode}/controls" ], body
    end
  end
end
