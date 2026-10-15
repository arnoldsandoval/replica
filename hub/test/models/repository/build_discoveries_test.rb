require "test_helper"

class Repository::BuildDiscoveriesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "creates one exact build across repeated discoveries" do
    repository = repositories.create

    assert_enqueued_jobs 1, only: Build::RecordCommitAuthorJob do
      first = repository.build_discoveries.record! \
        branch_name: "prototype/welcome",
        commit_sha: "a" * 40
      repeated = repository.build_discoveries.record! \
        branch_name: "prototype/welcome",
        commit_sha: "a" * 40

      assert_equal first, repeated
    end

    assert_equal 1, repository.prototypes.count
    assert_equal 1, repository.prototypes.first.builds.count
  end

  test "moves the current branch head without changing Build numbers" do
    repository = repositories.create
    older = repository.build_discoveries.record! \
      branch_name: "prototype/welcome",
      commit_sha: "a" * 40,
      branch_head: true
    assert_equal 1, older.prototype.reload.head_observation_revision
    newer = repository.build_discoveries.record! \
      branch_name: "prototype/welcome",
      commit_sha: "b" * 40,
      branch_head: true

    assert_equal newer, repository.prototypes.find_by!(branch_name: "prototype/welcome").current_build
    assert_equal 2, newer.prototype.reload.head_observation_revision
    assert_equal [ 1, 2 ], [ older.number, newer.number ]
  end

  test "repeated head observations advance the revision without creating another Build" do
    repository = repositories.create
    first = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "a" * 40, branch_head: true
    assert_equal 1, first.prototype.reload.head_observation_revision

    repeated = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: first.commit_sha, branch_head: true

    assert_equal first, repeated
    assert_equal first, first.prototype.reload.current_build
    assert_equal 2, first.prototype.head_observation_revision
    assert_equal 1, first.prototype.builds.count
  end

  test "history-only discoveries leave the head observation revision unchanged" do
    repository = repositories.create
    first = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "a" * 40
    assert_equal 0, first.prototype.reload.head_observation_revision
    assert_nil first.prototype.current_build_id

    current = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "b" * 40, branch_head: true
    repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "c" * 40

    assert_equal current, first.prototype.reload.current_build
    assert_equal 1, first.prototype.head_observation_revision
    assert_equal 3, first.prototype.builds.count
  end

  test "rejected recovery records history without advancing the head observation revision" do
    repository = repositories.create
    current = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "b" * 40,
      previous_commit_sha: "a" * 40, branch_head: true
    revision = current.prototype.reload.head_observation_revision
    repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: current.commit_sha, branch_head: true

    recovered = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "a" * 40, branch_head: true,
      expected_current_build_id: current.id, expected_head_observation_revision: revision

    assert_equal current, current.prototype.reload.current_build
    assert_equal revision + 1, current.prototype.head_observation_revision
    assert_equal "superseded", recovered.state
    assert_equal 2, current.prototype.builds.count
  end

  test "requires the current Build to belong to the Prototype" do
    repository = repositories.create
    prototype = prototypes.create(repository:, branch_name: "prototype/first")
    other = builds.create \
      prototype: prototypes.create(repository:, branch_name: "prototype/other"),
      commit_sha: "a" * 40

    assert_raises(ActiveRecord::StatementInvalid) do
      Prototype.where(id: prototype.id).update_all(current_build_id: other.id)
    end
  end

  test "does not requeue a completed commit author lookup" do
    repository = repositories.create
    build = repository.build_discoveries.record! \
      branch_name: "prototype/welcome",
      commit_sha: "a" * 40
    build.update!(commit_author_checked_at: Time.current, commit_author_requested_at: nil)
    clear_enqueued_jobs

    repository.build_discoveries.record! \
      branch_name: "prototype/welcome",
      commit_sha: build.commit_sha

    assert_enqueued_jobs 0, only: Build::RecordCommitAuthorJob
  end

  test "builds default branches without metadata imports registration or duplicate records" do
    repository = repositories.create
    first = nil
    assert_no_enqueued_jobs only: Build::ImportStartPageJob do
      first = repository.build_discoveries.record!(branch_name: "main", commit_sha: "a" * 40, branch_head: true)
      assert_equal first, repository.build_discoveries.record!(branch_name: "main", commit_sha: "a" * 40)
    end
    assert_predicate first.prototype, :replica?
    assert_not first.prototype.reviewable?
    assert_nil first.prototype.registered_at
    assert_equal first, repository.replica_build_owner.current_build
    assert_equal 1, first.prototype.builds.count
    assert_nil first.start_page_checked_at
  end

  test "ignores reserved branches and removed repositories" do
    repository = repositories.create

    assert_nil repository.build_discoveries.record!(
      branch_name: "replica/install-workflow",
      commit_sha: "b" * 40
    )

    repository.update!(installation_state: "removed", removed_at: Time.current)
    assert_nil repository.build_discoveries.record!( \
      branch_name: "prototype/welcome", commit_sha: "c" * 40
    )
    assert_empty repository.prototypes
  end

  test "delayed discovery of a former default reuses an internal owner after a rename" do
    repository = repositories.create
    assert_empty repository.prototypes
    repository.update!(default_branch: "trunk")

    build = nil
    assert_no_enqueued_jobs only: Build::ImportStartPageJob do
      build = repository.build_discoveries.record! \
        branch_name: "main",
        commit_sha: "a" * 40,
        branch_head: true
    end

    assert_predicate build.prototype, :replica?
    assert_not build.prototype.reviewable?
    assert_nil build.prototype.registered_at
    assert_empty repository.reviewable_prototypes
    assert_equal build, build.prototype.current_build
    assert_equal build, repository.build_discoveries.record!(branch_name: "main", commit_sha: "a" * 40)
    assert_equal 1, build.prototype.builds.count
    assert_raises(ActiveRecord::RecordNotFound) { build.prototype.register!(name: "Forbidden") }
    assert_equal %w[main trunk], repository.prototypes.order(:branch_name).pluck(:branch_name)
    assert repository.prototypes.all?(&:replica?)
  end

  test "supersedes only a proven queued predecessor" do
    repository = repositories.create
    older = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "a" * 40
    unrelated = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "b" * 40

    newer = repository.build_discoveries.record! \
      branch_name: "prototype/welcome",
      commit_sha: "c" * 40,
      previous_commit_sha: older.commit_sha

    assert_equal "superseded", older.reload.state
    assert_equal "queued", unrelated.reload.state
    assert_equal "queued", newer.state
  end

  test "discovery waiting on the repository lock sees owners saved by a default rename" do
    repository = repositories.create
    original_lock = repository.method(:with_lock)
    repository.define_singleton_method(:with_lock) do |&block|
      Repository.find(id).update!(default_branch: "trunk")
      original_lock.call(&block)
    end

    build = repository.build_discoveries.record! \
      branch_name: "main",
      commit_sha: "a" * 40,
      branch_head: true

    assert_predicate build.prototype, :replica?
    assert_equal repository.prototypes.find_by!(branch_name: "main"), build.prototype
    assert_empty repository.reviewable_prototypes
    assert_equal "trunk", repository.default_branch
  end

  test "does not supersede a running predecessor" do
    repository = repositories.create
    running = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "a" * 40
    running.update!(state: "running", started_at: Time.current)

    repository.build_discoveries.record! \
      branch_name: "prototype/welcome",
      commit_sha: "b" * 40,
      previous_commit_sha: running.commit_sha

    assert_equal "running", running.reload.state
  end

  test "stores an out-of-order predecessor as superseded" do
    repository = repositories.create
    newer = repository.build_discoveries.record! \
      branch_name: "prototype/welcome",
      commit_sha: "b" * 40,
      previous_commit_sha: "a" * 40

    older = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "a" * 40

    assert_equal "queued", newer.state
    assert_equal "superseded", older.state
  end

  test "applies push ordering to a build first found through polling" do
    repository = repositories.create
    older = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "a" * 40
    newer = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "b" * 40

    repeated = repository.build_discoveries.record! \
      branch_name: "prototype/welcome",
      commit_sha: newer.commit_sha,
      previous_commit_sha: older.commit_sha

    assert_equal newer, repeated
    assert_equal older.commit_sha, newer.reload.previous_commit_sha
    assert_equal "superseded", older.reload.state
  end

  test "supersedes a completed out-of-order predecessor chain" do
    repository = repositories.create
    oldest = repository.build_discoveries.record! \
      branch_name: "prototype/welcome", commit_sha: "a" * 40
    repository.build_discoveries.record! \
      branch_name: "prototype/welcome",
      commit_sha: "c" * 40,
      previous_commit_sha: "b" * 40

    middle = repository.build_discoveries.record! \
      branch_name: "prototype/welcome",
      commit_sha: "b" * 40,
      previous_commit_sha: oldest.commit_sha

    assert_equal "superseded", middle.state
    assert_equal "superseded", oldest.reload.state
  end
end
