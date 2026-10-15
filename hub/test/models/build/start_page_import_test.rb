require "test_helper"

class Build::StartPageImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @build = builds.create
    @prototype = @build.prototype
    @prototype.update!(current_build: @build)
    @configuration = github_app_configurations.create_installed
    stub_github_installation_token
  end

  test "imports from the exact commit without registering the prototype" do
    request = stub_file(@build, { startPage: "/settings?tab=profile#details", name: "Ignored" }.to_json)
    @build.start_page_import.fetch!(configuration: @configuration)
    assert_equal "/settings?tab=profile#details", @prototype.reload.start_page
    assert_not_nil @prototype.start_page_set_at
    assert_nil @prototype.name
    assert_nil @prototype.registered_at
    assert_not_nil @build.reload.start_page_checked_at
    assert_requested request
  end

  test "a delayed metadata job never reads a branch that became the default" do
    @prototype.repository.update!(default_branch: @prototype.branch_name)
    @build.start_page_import.fetch!(configuration: @configuration)

    assert_nil @prototype.reload.start_page
    assert_nil @build.reload.start_page_checked_at
    assert_not_requested :get, file_url(@build)
  end

  test "imports serialized template destinations without start-page errors" do
    {
      "/café?q=é#é" => "/caf%C3%A9?q=%C3%A9#%C3%A9",
      "/a^b" => "/a%5Eb",
      "/#/x%5B1%5D" => "/#/x%5B1%5D",
      "/?filter[state]=open" => "/?filter[state]=open",
      "/?q=#{'é' * 340}aaaa" => "/?q=#{'%C3%A9' * 340}aaaa"
    }.each.with_index do |(declared, serialized), index|
      assert Build::Templates.valid_path?(declared), declared
      @prototype = prototypes.create(repository: @prototype.repository, branch_name: "prototype/template-#{index}")
      build = builds.create(prototype: @prototype, commit_sha: (index + 2).to_s(16).rjust(40, "0"))
      @prototype.update!(current_build: build)
      stub_file(build, { startPage: serialized }.to_json)
      build.start_page_import.fetch!(configuration: @configuration)
      assert_equal serialized, @prototype.reload.start_page
      assert_nil @prototype.start_page_import_error
      assert_not_nil @prototype.start_page_set_at
    end
  end

  test "missing files allow a later commit to set the route" do
    stub_request(:get, file_url(@build)).to_return(status: 404)
    @build.start_page_import.fetch!(configuration: @configuration)
    assert_nil @prototype.reload.start_page_set_at
    assert_not_nil @build.reload.start_page_checked_at

    newer = next_build
    stub_file(newer, { startPage: "/later" }.to_json)
    newer.start_page_import.fetch!(configuration: @configuration)
    assert_equal "/later", @prototype.reload.start_page
  end

  test "later pushes and retries do not read the file once Hub owns the setting" do
    stub_file(@build, { startPage: "/first" }.to_json)
    @build.start_page_import.fetch!(configuration: @configuration)
    next_build.start_page_import.fetch!(configuration: @configuration)
    assert_equal "/first", @prototype.reload.start_page
  end

  test "an explicit Hub clear before import prevents any file lookup" do
    @prototype.register!(name: "Welcome", start_page: "")
    @build.start_page_import.fetch!(configuration: @configuration)
    assert_nil @prototype.reload.start_page
    assert_not_nil @prototype.start_page_set_at
    assert_not_requested :get, file_url(@build)
  end

  test "name and description edits alone do not claim the start page" do
    @prototype.register!(name: "Welcome")
    assert_nil @prototype.reload.start_page_set_at
    stub_file(@build, { startPage: "/welcome" }.to_json)
    @build.start_page_import.fetch!(configuration: @configuration)
    assert_equal "/welcome", @prototype.reload.start_page
  end

  test "invalid files expose an error but allow correction in the next commit" do
    [ "{", "[]", "{}", { startPage: "//evil.test" }.to_json,
      { startPage: "/a/../b" }.to_json, { startPage: "/%FF" }.to_json,
      { startPage: "/__replica/authorize" }.to_json, { startPage: "/a " }.to_json,
      { startPage: 42 }.to_json ].each do |content|
      build = next_build
      stub_file(build, content)
      build.start_page_import.fetch!(configuration: @configuration)
      assert_nil @prototype.reload.start_page_set_at
      assert_match(/Could not import/, @prototype.start_page_import_error)
      assert_equal "queued", build.reload.state
      assert_not_nil build.start_page_checked_at
    end
    newer = next_build
    stub_file(newer, { startPage: "/" }.to_json)
    newer.start_page_import.fetch!(configuration: @configuration)
    assert_equal "/", @prototype.reload.start_page
    assert_nil @prototype.start_page_import_error
  end

  test "network failures remain retryable and do not mark the file missing" do
    stub_request(:get, file_url(@build)).to_return(status: 503, body: "{}")
    assert_raises(GithubClient::Error) { @build.start_page_import.fetch!(configuration: @configuration) }
    assert_nil @build.reload.start_page_checked_at
    assert_nil @prototype.reload.start_page_set_at
  end

  test "oversized and malformed encoded files report an import error" do
    [ file_response("x" * 16_385),
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: { type: "file", encoding: "base64", size: 4, content: "!!!" }.to_json },
      file_response("{\"startPage\":\"/\xff\"}".b) ].each do |response|
      build = next_build
      stub_request(:get, file_url(build)).to_return(response)
      build.start_page_import.fetch!(configuration: @configuration)
      assert_nil @prototype.reload.start_page_set_at
      assert_not_nil @prototype.start_page_import_error
    end
  end

  test "accepts the exact metadata file size limit" do
    stub_file(@build, { startPage: "/" }.to_json.ljust(16_384))
    @build.start_page_import.fetch!(configuration: @configuration)
    assert_equal "/", @prototype.reload.start_page
  end

  test "installation token errors do not count as a missing file" do
    @configuration.tokens.define_singleton_method(:installation) do
      raise GithubClient::NotFound, "Missing installation"
    end
    assert_raises(GithubClient::NotFound) { @build.start_page_import.fetch!(configuration: @configuration) }
    assert_nil @build.reload.start_page_checked_at
  end

  test "a concurrent Hub edit wins over an in-flight import" do
    stub_request(:get, file_url(@build)).to_return do
      Prototype.find(@prototype.id).register!(name: "Welcome", start_page: "")
      file_response({ startPage: "/from-file" }.to_json)
    end
    @build.start_page_import.fetch!(configuration: @configuration)
    assert_nil @prototype.reload.start_page
    assert_not_nil @prototype.start_page_set_at
  end

  test "old jobs cannot initialize from a superseded head" do
    newer = next_build
    @build.start_page_import.fetch!(configuration: @configuration)
    assert_not_requested :get, file_url(@build)
    stub_file(newer, { startPage: "/new" }.to_json)
    newer.start_page_import.fetch!(configuration: @configuration)
    assert_equal "/new", @prototype.reload.start_page
  end

  test "discovery schedules the import independently of build completion" do
    assert_enqueued_jobs 1, only: Build::ImportStartPageJob do
      @prototype.repository.build_discoveries.record!(
        branch_name: @prototype.branch_name, commit_sha: "f" * 40, branch_head: true
      )
    end
    @prototype.register!(name: "Welcome", start_page: "")
    assert_no_enqueued_jobs only: Build::ImportStartPageJob do
      @prototype.repository.build_discoveries.record!(
        branch_name: @prototype.branch_name, commit_sha: "e" * 40, branch_head: true
      )
    end
  end

  private

  def next_build
    number = @prototype.builds.maximum(:number) + 1
    build = builds.create(prototype: @prototype, number:, commit_sha: number.to_s(16).rjust(40, "0"))
    @prototype.update!(current_build: build)
    build
  end

  def file_url(build)
    "#{GITHUB_API_URL}/repos/#{@prototype.repository.github_path}/contents/.prototype?ref=#{build.commit_sha}"
  end

  def file_response(content)
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: { type: "file", encoding: "base64", size: content.bytesize, content: Base64.strict_encode64(content) }.to_json }
  end

  def stub_file(build, content)
    stub_request(:get, file_url(build)).to_return(file_response(content))
  end
end
