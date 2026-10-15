require "test_helper"

class Repository::BranchPresenceTest < ActiveSupport::TestCase
  test "retirement keeps registration and a fixed head despite later historical Builds" do
    repository = repositories.create
    build = repository.build_discoveries.record!(branch_name: "topic", commit_sha: "a" * 40, branch_head: true)
    prototype = build.prototype
    prototype.register!(name: "Original", start_page: "/original")
    registered_at = prototype.registered_at
    observed = repository.branch_presence.observations.fetch("topic")

    repository.branch_presence.record_missing!(branch_name: "topic", observed:)
    repository.build_discoveries.record!(branch_name: "topic", commit_sha: "b" * 40, branch_head: true)
    repository.branch_presence.record_missing!(branch_name: "topic", observed:)

    assert prototype.reload.branch_deleted_at
    assert_equal "a" * 40, prototype.retired_head_sha
    assert_equal build, prototype.current_build
    assert_equal registered_at, prototype.registered_at
    assert_equal "/original", prototype.start_page
    assert_equal 2, prototype.head_observation_revision
    assert_equal 2, prototype.builds.count
    assert_not prototype.register_automatically!(commit_sha: build.commit_sha, author: users.create)
  end

  test "an equal returning head resumes the latest identity without a comparison" do
    configuration = installed_configuration
    repository = repositories.create
    prototype = retired_prototype(repository, "a" * 40)
    prototype.register!(name: "Original", start_page: "/original")

    resumed = repository.branch_presence.record_head!(
      branch_name: "topic", commit_sha: "a" * 40,
      observed: repository.branch_presence.observations.fetch("topic"), configuration:
    )

    assert_equal prototype, resumed.prototype
    assert_nil prototype.reload.branch_deleted_at
    assert_nil prototype.retired_head_sha
    assert_equal "Original", prototype.name
    assert_equal "/original", prototype.start_page
    assert_predicate prototype, :registered?
    assert_equal 1, repository.prototypes.count
  end

  test "a descendant resumes metadata and registration after GitHub confirms ancestry" do
    configuration = installed_configuration
    repository = repositories.create
    prototype = retired_prototype(repository, "a" * 40)
    prototype.register!(name: "Original")
    stub_ancestry(repository, "a" * 40, "b" * 40, merge_base: "a" * 40, status: "ahead")

    resumed = repository.branch_presence.record_head!(
      branch_name: "topic", commit_sha: "b" * 40,
      observed: repository.branch_presence.observations.fetch("topic"), configuration:
    )

    assert_equal prototype, resumed.prototype
    assert_nil prototype.reload.branch_deleted_at
    assert_predicate prototype, :registered?
    assert_equal resumed, prototype.current_build
    assert_equal 2, prototype.builds.count
  end

  test "a shared ancestor creates an independent unregistered identity" do
    configuration = installed_configuration
    repository = repositories.create
    original = retired_prototype(repository, "a" * 40)
    original.register!(name: "Original", start_page: "/original")
    stub_ancestry(repository, "a" * 40, "b" * 40, merge_base: "c" * 40, status: "diverged")

    replacement = repository.branch_presence.record_head!(
      branch_name: "topic", commit_sha: "b" * 40,
      observed: repository.branch_presence.observations.fetch("topic"), configuration:
    ).prototype

    assert_not_equal original.id, replacement.id
    assert original.reload.branch_deleted_at
    assert_predicate original, :registered?
    assert_nil replacement.name
    assert_nil replacement.start_page
    assert_not replacement.registered?
    assert_equal [ replacement.id ], repository.prototypes.active.pluck(:id)
    assert_equal [ "a" * 40 ], original.builds.pluck(:commit_sha)
    assert_equal [ "b" * 40 ], replacement.builds.pluck(:commit_sha)
    duplicate = repository.prototypes.new(branch_name: "topic")
    assert_not duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "an older matching history cannot replace the most recently retired identity" do
    configuration = installed_configuration
    repository = repositories.create
    older = retired_prototype(repository, "a" * 40)
    latest = prototypes.create(repository:, branch_name: "topic")
    head = builds.create(prototype: latest, commit_sha: "b" * 40)
    latest.update!(current_build: head)
    repository.branch_presence.record_missing!(
      branch_name: "topic", observed: repository.branch_presence.observations.fetch("topic")
    )
    stub_ancestry(repository, "b" * 40, "a" * 40, merge_base: "a" * 40, status: "behind")

    new_owner = repository.branch_presence.record_head!(
      branch_name: "topic", commit_sha: "a" * 40,
      observed: repository.branch_presence.observations.fetch("topic"), configuration:
    ).prototype

    assert_not_includes [ older.id, latest.id ], new_owner.id
    assert older.reload.branch_deleted_at
    assert latest.reload.branch_deleted_at
  end

  test "a returning branch starts separately when the retired head was never known" do
    configuration = installed_configuration
    repository = repositories.create
    original = prototypes.create(repository:, branch_name: "topic")
    builds.create(prototype: original, commit_sha: "a" * 40)
    repository.branch_presence.record_missing!(
      branch_name: "topic", observed: repository.branch_presence.observations.fetch("topic")
    )

    new_owner = repository.branch_presence.record_head!(
      branch_name: "topic", commit_sha: "a" * 40,
      observed: repository.branch_presence.observations.fetch("topic"), configuration:
    ).prototype

    assert_not_equal original.id, new_owner.id
    assert original.reload.branch_deleted_at
    assert_nil original.retired_head_sha
  end

  test "verification failures leave the retired identity untouched" do
    configuration = installed_configuration
    repository = repositories.create
    original = retired_prototype(repository, "a" * 40)
    comparison = stub_request(:get, "https://api.github.com/repos/#{repository.github_path}/compare/#{"a" * 40}...#{"b" * 40}")
      .to_return(status: 404, body: "{}")

    assert_raises(GithubClient::NotFound) do
      repository.branch_presence.record_head!(
        branch_name: "topic", commit_sha: "b" * 40,
        observed: repository.branch_presence.observations.fetch("topic"), configuration:
      )
    end
    comparison.to_return(status: 200, body: JSON.generate(status: "ahead"))
    assert_raises(GithubClient::InvalidResponse) do
      repository.branch_presence.record_head!(
        branch_name: "topic", commit_sha: "b" * 40,
        observed: repository.branch_presence.observations.fetch("topic"), configuration:
      )
    end

    assert original.reload.branch_deleted_at
    assert_equal 1, repository.prototypes.count
    assert_equal [ "a" * 40 ], original.builds.pluck(:commit_sha)
  end

  test "contradictory comparisons cannot create a new identity" do
    configuration = installed_configuration
    repository = repositories.create
    original = retired_prototype(repository, "a" * 40)
    comparison = stub_ancestry(repository, "a" * 40, "b" * 40, merge_base: "c" * 40, status: "behind")

    assert_raises(GithubClient::InvalidResponse) do
      repository.branch_presence.record_head! \
        branch_name: "topic",
        commit_sha: "b" * 40,
        observed: repository.branch_presence.observations.fetch("topic"),
        configuration:
    end
    comparison.to_return \
      status: 200,
      body: JSON.generate(status: "diverged", base_commit: { sha: "a" * 40 }, merge_base_commit: { sha: "b" * 40 })
    assert_raises(GithubClient::InvalidResponse) do
      repository.branch_presence.record_head! \
        branch_name: "topic",
        commit_sha: "b" * 40,
        observed: repository.branch_presence.observations.fetch("topic"),
        configuration:
    end

    assert original.reload.branch_deleted_at
    assert_equal "a" * 40, original.retired_head_sha
    assert_equal 1, repository.prototypes.count
    assert_equal [ "a" * 40 ], original.builds.pluck(:commit_sha)
  end

  test "a newer observation blocks a stale deletion even when the SHA repeats" do
    repository = repositories.create
    build = repository.build_discoveries.record!(branch_name: "topic", commit_sha: "a" * 40, branch_head: true)
    observed = repository.branch_presence.observations.fetch("topic")
    repository.build_discoveries.record!(branch_name: "topic", commit_sha: "a" * 40, branch_head: true)

    repository.branch_presence.record_missing!(branch_name: "topic", observed:)

    assert_nil build.prototype.reload.branch_deleted_at
    assert_equal 2, build.prototype.head_observation_revision
  end

  test "a stale scan cannot record a head on a replacement generation" do
    configuration = installed_configuration
    repository = repositories.create
    original = retired_prototype(repository, "a" * 40)
    observed = repository.branch_presence.observations.fetch("topic")
    replacement = prototypes.create(repository:, branch_name: "topic")
    stub_ancestry(repository, "a" * 40, "b" * 40, merge_base: "a" * 40, status: "ahead")

    assert_nil repository.branch_presence.record_head!(
      branch_name: "topic", commit_sha: "b" * 40, observed:, configuration:
    )
    assert_nil replacement.reload.current_build_id
    assert original.reload.branch_deleted_at
    assert_equal 1, Build.count
  end

  test "an ancestry response cannot undo a concurrent resumption" do
    configuration = installed_configuration
    repository = repositories.create
    original = retired_prototype(repository, "a" * 40)
    observed = repository.branch_presence.observations.fetch("topic")
    depth = ApplicationRecord.connection.open_transactions
    stub_request(:get, "https://api.github.com/repos/#{repository.github_path}/compare/#{"a" * 40}...#{"b" * 40}")
      .to_return do
        assert_equal depth, ApplicationRecord.connection.open_transactions
        repository.branch_presence.record_head!(
          branch_name: "topic", commit_sha: "a" * 40, observed:, configuration:
        )
        { status: 200, body: JSON.generate(
          status: "diverged", base_commit: { sha: "a" * 40 }, merge_base_commit: { sha: "c" * 40 }
        ) }
      end

    assert_nil repository.branch_presence.record_head!(
      branch_name: "topic", commit_sha: "b" * 40, observed:, configuration:
    )
    assert_nil original.reload.branch_deleted_at
    assert_equal "a" * 40, original.current_build.commit_sha
    assert_equal 1, repository.prototypes.count
  end

  test "an ordinary force push on an active branch keeps its identity" do
    configuration = installed_configuration
    repository = repositories.create
    head = repository.build_discoveries.record!(branch_name: "topic", commit_sha: "a" * 40, branch_head: true)

    replacement = repository.branch_presence.record_head!(
      branch_name: "topic", commit_sha: "b" * 40,
      observed: repository.branch_presence.observations.fetch("topic"), configuration:
    )

    assert_equal head.prototype, replacement.prototype
    assert_equal replacement, head.prototype.reload.current_build
    assert_equal 1, repository.prototypes.count
  end

  test "a default rename keeps every retained generation internal and selects an active owner" do
    repository = repositories.create
    original = retired_prototype(repository, "a" * 40)
    original.register!(name: "Retained")
    active = prototypes.create(repository:, branch_name: "topic")
    active.register!(name: "Active")

    repository.update!(default_branch: "topic")

    assert_equal active, repository.replica_build_owner
    assert_predicate original.reload, :replica?
    assert_predicate active.reload, :replica?
    assert_not original.registered?
    assert_not active.registered?
    assert_empty repository.reviewable_prototypes
    assert original.branch_deleted_at
  end

  test "a ref omission requires readable repository confirmation and malformed scans cannot retire" do
    configuration = installed_configuration
    repository = repositories.create
    original = retired_prototype(repository, "a" * 40)
    stub_request(:get, "https://api.github.com/repos/#{repository.github_path}/branches?per_page=100&page=1")
      .to_return(status: 200, body: "[]")
    stub_request(:get, "https://api.github.com/repos/#{repository.github_path}/git/ref/heads/topic")
      .to_return(status: 404, body: "{}")
    access = stub_request(:get, "https://api.github.com/repos/#{repository.github_path}")
      .to_return(status: 403, body: "{}")

    assert_raises(GithubClient::Forbidden) do
      repository.branch_presence.heads(configuration:, corroborate: [ "topic" ])
    end
    access.to_return(status: 200, body: JSON.generate(id: repository.github_id))
    assert_empty repository.branch_presence.heads(configuration:, corroborate: [ "topic" ])
    access.to_return(status: 200, body: JSON.generate(id: repository.github_id + 1))
    assert_raises(GithubClient::InvalidResponse) do
      repository.branch_presence.heads(configuration:, corroborate: [ "topic" ])
    end
    stub_request(:get, "https://api.github.com/repos/#{repository.github_path}/branches?per_page=100&page=1")
      .to_return(status: 200, body: JSON.generate([ { name: "topic", commit: { sha: "bad" } } ]))
    assert_raises(GithubClient::InvalidResponse) { repository.branch_presence.heads(configuration:) }
    assert original.reload.branch_deleted_at
  end

  test "a complete branch scan includes later pages and rejects repeated branch names" do
    configuration = installed_configuration
    repository = repositories.create
    first = 100.times.map { |index| { name: "topic-#{index}", commit: { sha: "a" * 40 } } }
    stub_request(:get, "https://api.github.com/repos/#{repository.github_path}/branches?per_page=100&page=1")
      .to_return(status: 200, body: JSON.generate(first))
    second = stub_request(:get, "https://api.github.com/repos/#{repository.github_path}/branches?per_page=100&page=2")
      .to_return(status: 200, body: JSON.generate([ { name: "topic", commit: { sha: "b" * 40 } } ]))

    assert_equal "b" * 40, repository.branch_presence.heads(configuration:).fetch("topic")
    second.to_return(status: 200, body: JSON.generate(first))
    assert_raises(GithubClient::InvalidResponse) { repository.branch_presence.heads(configuration:) }
    assert_not_requested :get, "https://api.github.com/repos/#{repository.github_path}/branches?per_page=100&page=3"
  end

  private

  def installed_configuration
    configuration = github_app_configurations.create_installed
    configuration.tokens.define_singleton_method(:installation) { "installation-token" }
    configuration
  end

  def retired_prototype(repository, sha)
    build = repository.build_discoveries.record!(branch_name: "topic", commit_sha: sha, branch_head: true)
    repository.branch_presence.record_missing!(
      branch_name: "topic", observed: repository.branch_presence.observations.fetch("topic")
    )
    build.prototype.reload
  end

  def stub_ancestry(repository, base, head, merge_base:, status:)
    stub_request(:get, "https://api.github.com/repos/#{repository.github_path}/compare/#{base}...#{head}")
      .to_return(status: 200, body: JSON.generate(
        status:, base_commit: { sha: base }, merge_base_commit: { sha: merge_base }
      ))
  end
end
