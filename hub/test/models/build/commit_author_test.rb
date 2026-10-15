require "test_helper"

class Build::CommitAuthorTest < ActiveSupport::TestCase
  test "fetches the exact commit with an installation token" do
    build = builds.create
    configuration = github_app_configurations.create_installed
    stub_github_installation_token
    request = stub_github_commit \
      build.prototype.repository,
      sha: build.commit_sha,
      avatar_url: "https://avatars.example.test/octocat"
    build.commit_author.fetch!(configuration:)

    assert_equal "octocat", build.reload.commit_author_login
    assert_requested request
  end

  test "records the commit author and associated GitHub account" do
    build = builds.create

    build.commit_author.record!(commit_payload(build.commit_sha))

    assert_equal "The Octocat", build.reload.commit_author_name
    assert_equal 1_001, build.commit_author_github_id
    assert_equal "octocat", build.commit_author_login
    assert_equal "https://avatars.example.test/octocat", build.commit_author_avatar_url
    assert_predicate build.commit_author_checked_at, :present?
    assert_equal "https://github.com/octocat", build.commit_author.profile_url
  end

  test "records a commit author without an associated GitHub account" do
    build = builds.create
    payload = commit_payload(build.commit_sha).merge("author" => nil)

    build.commit_author.record!(payload)

    assert_equal "The Octocat", build.reload.commit_author_name
    assert_nil build.commit_author_login
    assert_nil build.commit_author.profile_url
  end

  test "does not replace saved commit author details" do
    build = builds.create
    build.commit_author.record!(commit_payload(build.commit_sha))
    changed = commit_payload(build.commit_sha)
    changed.fetch("commit").fetch("author")["name"] = "Mona Lisa"
    changed.fetch("author")["login"] = "monalisa"

    build.commit_author.record!(changed)

    assert_equal "The Octocat", build.reload.commit_author_name
    assert_equal "octocat", build.commit_author_login
  end

  test "stops retrying when GitHub no longer provides the commit" do
    build = builds.create
    configuration = github_app_configurations.create_installed
    stub_github_installation_token
    stub_request(:get, "#{GITHUB_API_URL}/repos/github/prototype/commits/#{build.commit_sha}")
      .to_return(status: 404, body: JSON.generate(message: "Not Found"))

    build.commit_author.fetch!(configuration:)

    assert_predicate build.reload.commit_author_checked_at, :present?
    assert_nil build.commit_author_name
    assert_equal 0, Build::CommitAuthor.missing.where(id: build.id).count
  end

  test "stops retrying when GitHub rejects an unavailable commit" do
    build = builds.create
    configuration = github_app_configurations.create_installed
    stub_github_installation_token
    stub_request(:get, "#{GITHUB_API_URL}/repos/github/prototype/commits/#{build.commit_sha}")
      .to_return(status: 422, body: JSON.generate(message: "No commit found"))

    build.commit_author.fetch!(configuration:)

    assert_predicate build.reload.commit_author_checked_at, :present?
  end

  test "does not treat installation token failures as a missing commit" do
    build = builds.create(commit_author_requested_at: Time.current)
    configuration = github_app_configurations.create_installed
    configuration.tokens.define_singleton_method(:installation) do
      raise GithubClient::NotFound, "missing installation"
    end

    assert_raises(GithubClient::NotFound) do
      build.commit_author.fetch!(configuration:)
    end

    assert_nil build.reload.commit_author_checked_at
    assert_predicate build.commit_author_requested_at, :present?
  end

  test "marks malformed commit author data as checked" do
    build = builds.create
    configuration = github_app_configurations.create_installed
    stub_github_installation_token
    stub_request(:get, "#{GITHUB_API_URL}/repos/github/prototype/commits/#{build.commit_sha}")
      .to_return \
        status: 200,
        body: JSON.generate(sha: build.commit_sha, commit: { author: {} }, author: nil),
        headers: { "Content-Type" => "application/json" }

    build.commit_author.fetch!(configuration:)

    assert_predicate build.reload.commit_author_checked_at, :present?
  end

  private

  def commit_payload(sha)
    {
      "sha" => sha,
      "commit" => { "author" => { "name" => "The Octocat" } },
      "author" => {
        "id" => 1_001,
        "login" => "octocat",
        "avatar_url" => "https://avatars.example.test/octocat"
      }
    }
  end
end
