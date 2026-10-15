require "test_helper"

class SecurityAuditsTest < ActionDispatch::IntegrationTest
  setup do
    github_app_configurations.create_installed
    @payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ @payload ], permissions: { 2001 => "admin" })
    post github_authentication_path
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    get github_authentication_callback_path, params: { code: "code", state: }
    @user = User.find_by!(github_id: 1001)
    @repository = Repository.find_by!(github_id: 2001)
    @path = repository_security_audit_path(@repository.route_id)
  end

  test "repository admins see only retained records from the authorized repository" do
    SecurityAuditEvent.record!(action: "share_link.create", outcome: "succeeded",
      repository: @repository, actor: @user, context: { ip_address: "203.0.113.12", source: "browser" })
    SecurityAuditEvent.record!(action: "github_app.reset", outcome: "succeeded")
    other = repositories.create(github_id: 2002, name_with_owner: "github/other")
    stub_github_permissions([ repository_payload(2002, "github/other") ], { 2002 => "pull" })
    SecurityAuditEvent.record!(action: "canvas_connection.revoke", outcome: "succeeded", repository: other)
    SecurityAuditEvent.record!(action: "share_link.delete", outcome: "succeeded",
      repository: @repository, occurred_at: 91.days.ago)
    get @path, as: :json
    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert_equal [ "share_link.create" ], data.fetch("events").map { _1.fetch("action") }
    assert_includes response.body, "203.0.113.12"
    assert_equal @path, data.fetch("workspace").fetch("securityAuditPath")
    assert_equal @repository.route_id.to_s, data.fetch("workspace").fetch("selectedRepositoryId")
    assert_equal I18n.t("repository_workspace.repositories"),
      data.fetch("workspace").fetch("repositoryMenuLabel")
    assert_equal I18n.t("repository_workspace.theme_system"),
      data.fetch("workspace").fetch("systemThemeLabel")
    assert_equal I18n.t("repository_workspace.theme_light"),
      data.fetch("workspace").fetch("lightThemeLabel")
    assert_equal I18n.t("repository_workspace.theme_dark"),
      data.fetch("workspace").fetch("darkThemeLabel")
    assert_not data.key?("administrationWorkspace")
    assert_equal @repository.route_id.to_s, data.fetch("selectedScopeId")
    assert_equal [ @repository.route_id.to_s ], data.fetch("scopes").pluck("id")
    assert_empty data.fetch("workspace").fetch("administrationLinks")
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end

  test "audit choices require fresh independent admin permission for each repository" do
    other_payload = repository_payload(2002, "github/empty")
    other = repositories.create(github_id: 2002, name_with_owner: "github/empty")
    stub_github_permissions([ other_payload ], { 2002 => "admin" })
    @user.update!(hub_admin: true)
    get @path, as: :json
    data = JSON.parse(response.body).fetch("data")
    assert_equal [ "hub", other.route_id.to_s, @repository.route_id.to_s ], data.fetch("scopes").pluck("id")
    assert_equal [ security_audit_path, repository_security_audit_path(other.route_id), @path ],
      data.fetch("scopes").pluck("path")
    stub_github_permissions([ @payload, other_payload ], { 2001 => "pull", 2002 => "pull" })
    get security_audit_path, as: :json
    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert_equal [ "hub" ], data.fetch("scopes").pluck("id")
    assert_nil data.fetch("scopesUnavailableMessage")
    assert_equal "hub", data.fetch("selectedScopeId")
    get @path
    assert_response :not_found
  end

  test "an optional scope failure is explicit without denying a separately authorized scope" do
    other_payload = repository_payload(2002, "github/empty")
    repositories.create(github_id: 2002, name_with_owner: "github/empty")
    stub_github_permissions([ other_payload ], { 2002 => :failure })
    get @path, as: :json
    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert_equal [ @repository.route_id.to_s ], data.fetch("scopes").pluck("id")
    assert_equal I18n.t("security_audit.scopes_unavailable"), data.fetch("scopesUnavailableMessage")
    @user.update!(hub_admin: true)
    stub_github_permissions([ @payload ], { 2001 => :failure })
    get security_audit_path, as: :json
    assert_response :success
    assert_equal [ "hub" ], JSON.parse(response.body).fetch("data").fetch("scopes").pluck("id")
    get @path
    assert_response :service_unavailable
  end

  test "a repository context hint never turns Hub records into repository records" do
    @user.update!(hub_admin: true)
    SecurityAuditEvent.record!(action: "share_link.create", outcome: "succeeded", repository: @repository)
    get security_audit_path, params: { repository_github_id: @repository.route_id }, as: :json
    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert_equal "hub", data.fetch("selectedScopeId")
    assert_equal @repository.route_id.to_s,
      data.fetch("administrationWorkspace").fetch("repository").fetch("selectedRepositoryId")
    assert_equal security_audit_path, data.fetch("administrationWorkspace").fetch("securityAuditPath")
    assert_not_includes data.fetch("events").pluck("action"), "share_link.create"
  end

  test "global audit requires operator status and does not grant repository access" do
    get security_audit_path
    assert_response :not_found
    @user.update!(hub_admin: true)
    get security_audit_path, as: :json
    assert_response :success
    actions = JSON.parse(response.body).fetch("data").fetch("events").map { _1.fetch("action") }
    assert_includes actions, "github_app_setup.exchange"
    SecurityAuditEvent.record!(action: "share_link.create", outcome: "succeeded", repository: @repository)
    get security_audit_path, as: :json
    assert_not_includes response.body, "share_link.create"
    stub_github_permissions([ @payload ], { 2001 => nil })
    get @path
    assert_response :not_found
    get repository_path(@repository.route_id)
    assert_response :not_found
    assert_equal "denied", SecurityAuditEvent.where(action: "security_audit.view").last.outcome
  end

  test "every repository audit read rechecks permission and fails closed" do
    get @path
    assert_response :success
    [ "push", "pull", nil, :failure ].each do |permission|
      stub_github_permissions([ @payload ], { 2001 => permission })
      get @path
      assert_response(permission == :failure ? :service_unavailable : :not_found)
    end
  end

  test "operators cannot read repository records after the repository is deleted" do
    @user.update!(hub_admin: true)
    repository = repositories.create(github_id: 2002)
    event = SecurityAuditEvent.record!(action: "share_link.delete", outcome: "succeeded", repository:)
    repository.destroy!

    get security_audit_path, as: :json
    assert_response :success
    assert_not_includes response.body, "share_link.delete"
    assert SecurityAuditEvent.retained.exists?(event.id)
  end

  test "anonymous readers cannot access either audit scope" do
    delete session_path
    get security_audit_path
    assert_redirected_to root_path
    get @path
    assert_redirected_to root_path
    assert_nil SecurityAuditEvent.last.user_id
    assert_equal "denied", SecurityAuditEvent.last.outcome
  end

  test "pagination stays scoped even when given another repository's identifier" do
    51.times do
      SecurityAuditEvent.record!(action: "share_link.create", outcome: "succeeded", repository: @repository)
    end
    get @path, as: :json
    data = JSON.parse(response.body).fetch("data")
    assert_equal 50, data.fetch("events").length
    get data.fetch("nextPath"), as: :json
    assert_response :success
    assert_equal 1, JSON.parse(response.body).fetch("data").fetch("events").length
    get @path, params: { before: "invalid" }
    assert_response :not_found
  end
end
