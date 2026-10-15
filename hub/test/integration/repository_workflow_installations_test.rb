require "test_helper"

class RepositoryWorkflowInstallationsTest < ActionDispatch::IntegrationTest
  BUILD_ACTION = "github/replica/actions/build@#{"a" * 40}"

  setup do
    github_app_configurations.create_installed
    @original_build_action = Rails.configuration.x.build_action
    @original_build_action_revisions = Rails.configuration.x.build_action_revisions
    Rails.configuration.x.build_action = BUILD_ACTION
    Rails.configuration.x.build_action_revisions = Set.new
  end

  teardown do
    Rails.configuration.x.build_action = @original_build_action
    Rails.configuration.x.build_action_revisions = @original_build_action_revisions
  end

  test "allows a writer to open the workflow installation pull request" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "push" })
    sign_in
    repository = Repository.find_by!(github_id: 2001)
    stub_workflow_pull_request(repository)

    post repository_workflow_installation_path(repository.github_id)

    assert_response :see_other
    assert_redirected_to "https://github.com/github/prototype/pull/25"
  end

  test "does not allow a reader to create repository content" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "pull" })
    sign_in

    post repository_workflow_installation_path(2001)

    assert_response :not_found
    assert_not_requested :get, %r{/contents/\.github/workflows/replica\.yml}
  end

  test "shows the installation action to a repository writer" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "push" })
    sign_in
    repository = Repository.find_by!(github_id: 2001)
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "main" })
      .to_return(status: 404, body: JSON.generate(message: "Not Found"))

    get repository_path(repository.github_id)

    assert_response :success
    assert_includes response.body, "Prototype workflow file missing"
    assert_includes response.body, "Open installation pull request"
    assert_includes response.body, repository_workflow_installation_path(repository.github_id)
  end

  test "links a reader to the workflow guide when installation requires a writer" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "pull" })
    sign_in
    repository = Repository.find_by!(github_id: 2001)
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "main" })
      .to_return(status: 404, body: JSON.generate(message: "Not Found"))

    get repository_path(repository.github_id)

    assert_response :success
    assert_includes response.body, "Prototype workflow file missing"
    assert_includes response.body, "Learn about the workflow"
    assert_includes response.body, "https://github.com/github/replica#prototype-build-workflow"
    assert_not_includes response.body, "Open installation pull request"
  end

  test "does not show workflow installation after the workflow exists" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "push" })
    sign_in
    repository = Repository.find_by!(github_id: 2001)
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "main" })
      .to_return(
        status: 200,
        body: workflow_payload(repository.workflow_installation.send(:workflow), "d" * 40)
      )

    get repository_path(repository.github_id)

    assert_response :success
    assert_not_includes response.body, "Open installation pull request"
    assert_not_includes response.body, "Prototype workflow"

    post repository_workflow_installation_path(repository.github_id)

    assert_redirected_to repository_path(repository.github_id)
    follow_redirect!
    assert_includes response.body, "No pull request is needed"
  end

  test "shows an update action when the installed build Action changed" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "push" })
    sign_in
    repository = Repository.find_by!(github_id: 2001)
    Rails.configuration.x.build_action_revisions = Set.new([ "b" * 40 ])
    previous_action = "github/replica/actions/build@#{"b" * 40}"
    installed_workflow = repository.workflow_installation.send(:workflow)
      .sub(BUILD_ACTION, previous_action)
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "main" })
      .to_return(status: 200, body: workflow_payload(installed_workflow, "d" * 40))

    get repository_path(repository.github_id)

    assert_response :success
    assert_includes response.body, "Replica workflow update available"
    assert_includes response.body, "Open workflow update pull request"
  end

  test "hides the update action for a customized legacy workflow" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "push" })
    sign_in
    repository = Repository.find_by!(github_id: 2001)
    installed_workflow = repository.workflow_installation.send(:workflow)
      .sub(BUILD_ACTION, "github/replica/actions/build@#{"b" * 40}")
      .sub("name: Replica", "name: Customized Replica")
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "main" })
      .to_return(status: 200, body: workflow_payload(installed_workflow, "d" * 40))

    get repository_path(repository.github_id)

    assert_response :success
    assert_not_includes response.body, "Open workflow update pull request"
    assert_not_includes response.body, "Build Action update available"
  end

  test "offers the default-branch workflow migration with the same Action pin and no automatic writes" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "push" })
    sign_in
    repository = Repository.find_by!(github_id: 2001)
    installed_workflow = repository.workflow_installation.send(:workflow).sub \
      "if: github.ref_name != 'replica/install-workflow'",
      "if: github.ref_name != github.event.repository.default_branch && github.ref_name != 'replica/install-workflow'"
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "main" })
      .to_return(status: 200, body: workflow_payload(installed_workflow, "d" * 40))

    get repository_path(repository.github_id), as: :json

    assert_response :success
    installation = JSON.parse(response.body).fetch("data").fetch("workflowInstallation")
    assert_equal "updatable", installation.fetch("state")
    assert_equal "Open workflow update pull request", installation.fetch("actionLabel")
    assert_equal repository_workflow_installation_path(repository.route_id), installation.fetch("createPath")
    assert_includes installed_workflow, "- uses: #{BUILD_ACTION}"
    assert_not_requested :put, workflow_url(repository)
    assert_not_requested :post, "#{GITHUB_API_URL}/repos/#{repository.name_with_owner}/pulls"
  end

  test "explains when the workflow branch cannot be safely reused" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "push" })
    sign_in
    repository = Repository.find_by!(github_id: 2001)
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "main" })
      .to_return(status: 404, body: JSON.generate(message: "Not Found"))
    stub_request(:get, reference_url(repository, "main"))
      .to_return(status: 200, body: JSON.generate(object: { sha: "b" * 40 }))
    stub_request(:get, reference_url(repository, "replica/install-workflow"))
      .to_return(status: 200, body: JSON.generate(object: { sha: "c" * 40 }))
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "replica/install-workflow" })
      .to_return(status: 200, body: workflow_payload("unrelated workflow", "d" * 40))

    post repository_workflow_installation_path(repository.github_id)

    assert_redirected_to repository_path(repository.github_id)
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Hub cannot safely reuse the replica/install-workflow branch"
    assert_includes response.body, "Open installation pull request"
  end

  test "explains when GitHub does not permit opening the pull request" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "push" })
    sign_in
    repository = Repository.find_by!(github_id: 2001)
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "main" })
      .to_return(status: 404, body: JSON.generate(message: "Not Found"))
    stub_request(:get, reference_url(repository, "main"))
      .to_return(status: 403, body: JSON.generate(message: "Forbidden"))

    post repository_workflow_installation_path(repository.github_id)

    assert_redirected_to repository_path(repository.github_id)
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Check the GitHub App"
    assert_not_includes response.body, "GitHub returned HTTP 403"
  end

  test "explains when Hub cannot confirm repository access before submitting" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "push" })
    sign_in
    repository = Repository.find_by!(github_id: 2001)
    stub_request(
      :get,
      "#{GITHUB_API_URL}/repos/#{repository.name_with_owner}/collaborators/octocat/permission"
    ).to_timeout

    post repository_workflow_installation_path(repository.github_id)

    assert_response :service_unavailable
    assert_includes response.body, "could not confirm your repository access"
    assert_not_requested :get, workflow_url(repository)
  end

  test "keeps the repository page available when the workflow check fails" do
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "push" })
    sign_in
    repository = Repository.find_by!(github_id: 2001)
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "main" })
      .to_timeout

    get repository_path(repository.github_id)

    assert_response :success
    assert_includes response.body, "could not check the repository workflow right now"
  end

  private

  def sign_in
    sign_in_to_hub
  end

  def stub_workflow_pull_request(repository)
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "main" })
      .to_return(status: 404, body: JSON.generate(message: "Not Found"))
    stub_request(:get, reference_url(repository, "main"))
      .to_return(status: 200, body: JSON.generate(object: { sha: "b" * 40 }))
    stub_request(:get, reference_url(repository, "replica/install-workflow"))
      .to_return(
        { status: 404, body: JSON.generate(message: "Not Found") },
        { status: 200, body: JSON.generate(object: { sha: "c" * 40 }) }
      )
    stub_request(:post, "#{GITHUB_API_URL}/repos/#{repository.name_with_owner}/git/refs")
      .to_return(status: 201, body: JSON.generate(ref: "refs/heads/replica/install-workflow"))
    stub_request(:put, workflow_url(repository))
      .to_return(status: 201, body: JSON.generate(content: { path: workflow_path }))
    stub_request(:get, workflow_url(repository))
      .with(query: { "ref" => "replica/install-workflow" })
      .to_return(
        status: 200,
        body: workflow_payload(repository.workflow_installation.send(:workflow), "d" * 40)
      )
    stub_request(:get, comparison_url(repository))
      .to_return \
        status: 200,
        body: JSON.generate(
          status: "ahead",
          ahead_by: 1,
          behind_by: 0,
          total_commits: 1,
          merge_base_commit: { sha: "b" * 40 },
          commits: [ { sha: "c" * 40 } ],
          files: [ { filename: workflow_path, status: "added" } ]
        )
    stub_request(:get, "#{GITHUB_API_URL}/repos/#{repository.name_with_owner}/pulls")
      .with(query: {
        "base" => "main",
        "head" => "github:replica/install-workflow",
        "state" => "open"
      })
      .to_return(status: 200, body: JSON.generate([]))
    stub_request(:post, "#{GITHUB_API_URL}/repos/#{repository.name_with_owner}/pulls")
      .to_return \
        status: 201,
        body: JSON.generate(
          number: 25,
          html_url: "https://github.com/github/prototype/pull/25"
        )
  end

  def workflow_path
    Repository::WorkflowInstallation::WORKFLOW_PATH
  end

  def workflow_url(repository)
    "#{GITHUB_API_URL}/repos/#{repository.name_with_owner}/contents/#{workflow_path}"
  end

  def reference_url(repository, branch)
    "#{GITHUB_API_URL}/repos/#{repository.name_with_owner}/git/ref/heads/#{branch}"
  end

  def comparison_url(repository)
    "#{GITHUB_API_URL}/repos/#{repository.name_with_owner}/compare/main...replica%2Finstall-workflow"
  end

  def workflow_payload(content, sha)
    JSON.generate(content: Base64.strict_encode64(content), sha: sha)
  end
end
