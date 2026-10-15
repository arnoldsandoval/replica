require "test_helper"

class WelcomeTest < ActionDispatch::IntegrationTest
  test "anonymous users cannot view or hide welcome" do
    get welcome_path
    assert_redirected_to root_path

    patch welcome_path
    assert_redirected_to root_path
    assert_equal 0, User.count
  end

  test "opens on first sign-in only and stays directly accessible after hiding" do
    github_app_configurations.create_installed
    repository = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ repository ], permissions: { 2001 => "pull" })

    sign_in
    assert_redirected_to welcome_path
    user = User.find_by!(github_id: 1001)
    get welcome_path, headers: { "Accept" => "application/json" }
    assert_response :success
    data = response.parsed_body.fetch("data")
    assert_equal "Turn an idea into an interactive prototype.", data.fetch("description")
    assert_equal "Create prototype", data.fetch("createLabel")
    assert_equal repository_new_prototype_path(2001), data.fetch("workspace").fetch("repository").fetch("newPrototypePath")
    assert_equal welcome_path(repository_github_id: 2001), data.fetch("workspace").fetch("welcomePath")
    assert_equal "welcome", data.fetch("workspace").fetch("selectedSection")
    assert_equal welcome_path(repository_github_id: 2001), data.fetch("hidePath")
    assert_equal "Getting started", data.fetch("setupLabel")
    assert_equal "https://github.com/github/replica/blob/main/docs/getting-started.md", data.fetch("setupPath")
    assert_equal "private, no-store", response.headers["Cache-Control"]

    other_browser = open_session
    other_browser.post github_authentication_path
    state = Rack::Utils.parse_query(URI(other_browser.response.location).query).fetch("state")
    other_browser.get github_authentication_callback_path, params: { code: "code", state: }
    assert_equal repositories_url, other_browser.response.location
    other_user = users.create(github_id: 1002, login: "mona")

    patch welcome_path, params: { user_id: other_user.id }
    assert_redirected_to welcome_path(repository_github_id: 2001)
    assert user.reload.welcome_hidden?
    assert_not other_user.reload.welcome_hidden?
    follow_redirect! headers: { "Accept" => "application/json" }
    assert_response :success
    data = response.parsed_body.fetch("data")
    assert_nil data.fetch("hidePath")
    assert_nil data.fetch("workspace").fetch("welcomePath")
    assert_equal I18n.t("welcome.hidden"), data.fetch("notice")

    other_browser.get welcome_path, headers: { "Accept" => "application/json" }
    assert_equal 200, other_browser.response.status
    assert_nil other_browser.response.parsed_body.fetch("data").fetch("workspace").fetch("welcomePath")

    delete session_path
    sign_in
    assert_redirected_to repositories_path
    get welcome_path, headers: { "Accept" => "application/json" }
    assert_response :success
    assert_nil response.parsed_body.fetch("data").fetch("workspace").fetch("welcomePath")
    get repository_path(2001), headers: { "Accept" => "application/json" }
    assert_response :success
    assert_nil response.parsed_body.fetch("data").fetch("welcomePath")
  end

  test "hiding welcome requires a browser authenticity token" do
    github_app_configurations.create_installed
    repository = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ repository ], permissions: { 2001 => "pull" })
    sign_in
    user = User.find_by!(github_id: 1001)
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    patch welcome_path

    assert_response :unprocessable_entity
    assert_not user.reload.welcome_hidden?
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "returning users keep their normal landing page without hiding welcome" do
    github_app_configurations.create_installed
    users.create(welcome_sign_in_pending: false)
    repository = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ repository ], permissions: { 2001 => "pull" })

    sign_in
    assert_redirected_to repositories_path
    get welcome_path, headers: { "Accept" => "application/json" }
    assert_response :success
    assert_equal welcome_path(repository_github_id: 2001), response.parsed_body.fetch("data").fetch("workspace").fetch("welcomePath")
  end

  test "opening and hiding welcome preserves the selected readable repository" do
    github_app_configurations.create_installed
    repositories = [
      repository_payload(2001, "github/alpha"),
      repository_payload(2002, "github/zulu")
    ]
    stub_github_sign_in(repositories:, permissions: { 2001 => "pull", 2002 => "pull" })
    sign_in
    context_path = welcome_path(repository_github_id: 2002)

    get repository_path(2002), headers: { "Accept" => "application/json" }
    assert_response :success
    assert_equal context_path, response.parsed_body.fetch("data").fetch("welcomePath")

    get context_path, headers: { "Accept" => "application/json" }
    assert_response :success
    data = response.parsed_body.fetch("data")
    assert_equal context_path, data.fetch("workspace").fetch("welcomePath")
    assert_equal context_path, data.fetch("hidePath")
    assert_equal repository_new_prototype_path(2002), data.fetch("workspace").fetch("repository").fetch("newPrototypePath")

    patch data.fetch("hidePath")
    assert_redirected_to context_path
    follow_redirect! headers: { "Accept" => "application/json" }
    assert_response :success
    data = response.parsed_body.fetch("data")
    assert_equal repository_new_prototype_path(2002), data.fetch("workspace").fetch("repository").fetch("newPrototypePath")
    assert_nil data.fetch("workspace").fetch("welcomePath")
    assert_nil data.fetch("hidePath")
  end

  test "welcome remains available when the user has no readable repositories" do
    github_app_configurations.create_installed
    users.create(hub_admin: true, welcome_sign_in_pending: false)
    stub_github_oauth_user

    sign_in
    get welcome_path, headers: { "Accept" => "application/json" }
    assert_response :success
    assert_nil response.parsed_body.fetch("data").fetch("workspace").fetch("repository")
  end

  test "unavailable repository context is not carried into welcome actions" do
    github_app_configurations.create_installed
    repository = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ repository ], permissions: { 2001 => "pull" })
    sign_in

    get welcome_path(repository_github_id: 9999), headers: { "Accept" => "application/json" }
    assert_response :success
    data = response.parsed_body.fetch("data")
    assert_nil data.fetch("workspace").fetch("repository")
    assert_equal welcome_path, data.fetch("workspace").fetch("welcomePath")
    assert_equal welcome_path, data.fetch("hidePath")

    patch welcome_path(repository_github_id: 9999)
    assert_redirected_to welcome_path
  end

  test "the configured hosted video is presented with its media policy" do
    github_app_configurations.create_installed
    repository = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ repository ], permissions: { 2001 => "pull" })
    sign_in
    previous_url = Rails.configuration.x.welcome_video_url
    Rails.configuration.x.welcome_video_url = "https://media.example.test/welcome.mp4"

    get welcome_path, headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal "https://media.example.test/welcome.mp4", response.parsed_body.fetch("data").fetch("videoUrl")
    assert_nil response.parsed_body.fetch("data").fetch("videoEmbedUrl")
    assert_includes response.headers["Content-Security-Policy"], "media-src 'self' https://media.example.test"
  ensure
    Rails.configuration.x.welcome_video_url = previous_url
  end

  test "the configured YouTube video is presented as a privacy-enhanced embed" do
    github_app_configurations.create_installed
    repository = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ repository ], permissions: { 2001 => "pull" })
    sign_in
    previous_url = Rails.configuration.x.welcome_video_url
    Rails.configuration.x.welcome_video_url = "https://www.youtube.com/watch?v=J2Z28CwIfsA"

    get welcome_path, headers: { "Accept" => "application/json" }

    assert_response :success
    data = response.parsed_body.fetch("data")
    assert_nil data.fetch("videoUrl")
    assert_equal "https://www.youtube-nocookie.com/embed/J2Z28CwIfsA", data.fetch("videoEmbedUrl")
    assert_includes response.headers["Content-Security-Policy"],
      "https://www.youtube-nocookie.com"
  ensure
    Rails.configuration.x.welcome_video_url = previous_url
  end

  private

  def sign_in
    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
  end
end
