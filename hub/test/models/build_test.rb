require "test_helper"

class BuildTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "identifies one build by prototype and exact commit" do
    build = builds.create

    duplicate = builds.new \
      prototype: build.prototype,
      number: 2,
      commit_sha: build.commit_sha

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:commit_sha], "has already been taken"
  end

  test "requires state timestamps to agree" do
    build = builds.new(state: "successful")

    assert_not build.valid?
    assert_includes build.errors[:base], "build timestamps do not match state"
  end

  test "enforces commit identity in the database" do
    build = builds.new(commit_sha: "not-a-commit-sha")
    attributes = build.attributes.except("id")

    assert_raises(ActiveRecord::StatementInvalid) { Build.insert_all!([ attributes ]) }
  end

  test "does not allow commit identity to change" do
    build = builds.create

    assert_not build.update(commit_sha: "c" * 40)
    assert_includes build.errors[:commit_sha], "cannot change"
  end

  test "requires complete commit author account identity" do
    build = builds.new(commit_author_name: "The Octocat", commit_author_login: "octocat")

    assert_not build.valid?
    assert_includes build.errors[:base], "commit author identity is incomplete"
  end

  test "enforces complete commit author account identity in the database" do
    build = builds.new(commit_author_name: "The Octocat", commit_author_github_id: 1_001)
    attributes = build.attributes.except("id")

    assert_raises(ActiveRecord::StatementInvalid) { Build.insert_all!([ attributes ]) }
  end

  test "backfills commit authors only for active repositories" do
    active = builds.create
    removed_repository = repositories.create(github_id: 2_002, name_with_owner: "github/removed")
    removed = builds.create(prototype: prototypes.create(repository: removed_repository), commit_sha: "b" * 40)
    removed.prototype.repository.update!(installation_state: "removed", removed_at: Time.current)

    assert_includes Build::CommitAuthor.missing, active
    assert_not_includes Build::CommitAuthor.missing, removed
  end

  test "queues only one recent commit author request" do
    build = builds.create

    assert_enqueued_jobs 1, only: Build::RecordCommitAuthorJob do
      assert build.commit_author.request!
      assert_not build.commit_author.request!
    end
  end

  test "enforces complete workflow identity in the database" do
    build = builds.new(number: 72, commit_sha: "7" * 40)
    attributes = build.attributes.except("id").merge("github_workflow_run_id" => 9001)

    assert_raises(ActiveRecord::StatementInvalid) do
      Build.insert_all!([ attributes ])
    end
  end

  test "requires workflow links to use the configured GitHub origin" do
    build = builds.new \
      github_workflow_run_id: 9001,
      github_workflow_run_attempt: 1,
      workflow_url: "https://example.com/github/prototype/actions/runs/9001"

    assert_not build.valid?
    assert_includes build.errors[:workflow_url], "must use the configured GitHub website over HTTPS"
  end

  test "enforces complete successful publication evidence in the database" do
    build = completed_build
    attributes = build.attributes.except("id").merge \
      "number" => 73,
      "commit_sha" => "8" * 40,
      "state" => "successful",
      "finished_at" => Time.current

    assert_raises(ActiveRecord::StatementInvalid) do
      Build.insert_all!([ attributes ])
    end
  end

  test "requires publication to use the Build's storage prefix" do
    build = completed_build
    build.update!(github_artifact_id: 8001)
    build.assign_attributes \
      state: "successful",
      finished_at: Time.current,
      artifact_prefix: "builds/#{build.id + 1}",
      artifact_bytes: 1

    assert_not build.valid?
    assert_includes build.errors[:artifact_prefix], "must match this build"
  end

  private

  def completed_build
    build = builds.create
    build.workflow_run.record! \
      run_id: 9001,
      run_attempt: 1,
      workflow_url: "https://github.com/github/prototype/actions/runs/9001",
      workflow_created_at: Time.iso8601("2026-09-17T18:00:00Z"),
      stage: "completed",
      conclusion: "success"
    build
  end
end
