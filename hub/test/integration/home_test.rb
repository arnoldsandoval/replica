require "test_helper"

class HomeTest < ActionDispatch::IntegrationTest
  { "repository user" => false, "Hub administrator" => true }.each do |role, hub_admin|
    test "redirects a signed-in #{role} to repositories" do
      github_app_configurations.create_installed
      users.create(hub_admin:)
      stub_github_sign_in \
        repositories: [ repository_payload(2001, "github/prototype") ],
        permissions: { 2001 => "pull" }
      post github_authentication_path
      state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
      get github_authentication_callback_path, params: { code: "code", state: }
      assert_redirected_to welcome_path

      get root_path

      assert_redirected_to repositories_path
    end
  end

  test "renders the application entry point" do
    get root_path

    assert_response :success
    assert_select "html[data-color-mode='auto'][data-light-theme='light'][data-dark-theme='dark']"
    assert_select "meta[name='color-scheme'][content='light dark']"
    assert_select "#app"
    assert_includes response.body, "home/index"
    assert_includes response.body, I18n.t("home.index.heading")
    assert_includes response.body, I18n.t("home.index.description")
    assert_includes response.body, I18n.t("home.index.badge")
    assert_includes response.body, I18n.t("home.index.badge_alternate")
    assert_includes response.body, I18n.t("home.index.footer_note", year: Date.current.year)
  end

  test "enforces the Hub policy and gives every bootstrap script a fresh response nonce" do
    get root_path
    assert_response :success

    nonce = css_select("meta[name='csp-nonce']").first["content"]
    assert_match(/\A[A-Za-z0-9+\/]{43}=\z/, nonce)
    assert_nil response.headers["Content-Security-Policy-Report-Only"]
    assert_equal \
      HubContentSecurityPolicy.build(development: false).build(Object.new, nonce, %w[script-src]),
      response.headers["Content-Security-Policy"]
    scripts = css_select("script")
    assert_operator scripts.length, :>=, 2
    scripts.each { assert_equal nonce, _1["nonce"] }
    assert_select "script[type='module'][src]"
    assert_select "script[nonce]", text: /SUPERGLUE_INITIAL_PAGE_STATE=/

    get root_path
    assert_response :success
    second_nonce = css_select("meta[name='csp-nonce']").first["content"]
    assert_not_equal nonce, second_nonce
    assert_includes response.headers["Content-Security-Policy"], "'nonce-#{second_nonce}'"
    assert_not_includes response.headers["Content-Security-Policy"], "'nonce-#{nonce}'"
  end
end
