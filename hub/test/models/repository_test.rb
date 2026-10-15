require "test_helper"

class RepositoryTest < ActiveSupport::TestCase
  setup { seed "repositories/github_empty" }

  test "does not allow the stable GitHub identity to change" do
    repository = repositories.github_empty

    assert_not repository.update(github_id: 9999)
    assert_includes repository.errors[:github_id], "cannot change"
  end

  test "requires a removal timestamp for removed repositories" do
    repository = repositories.github_empty

    assert_not repository.update(installation_state: "removed")
    assert_includes repository.errors[:removed_at], "does not match installation state"
  end

  test "default renames save marker owners and roll back with the repository" do
    repository = repositories.github_empty

    Repository.transaction do
      repository.update!(default_branch: "trunk")
      assert_equal %w[main trunk], repository.prototypes.order(:branch_name).pluck(:branch_name)
      assert repository.prototypes.all?(&:replica?)
      raise ActiveRecord::Rollback
    end

    assert_equal "main", repository.reload.default_branch
    assert_empty repository.prototypes
    assert_not repository.update(default_branch: " ")
    assert_empty repository.prototypes
  end

  test "default renames keep the existing owner's metadata author and Builds" do
    repository = repositories.github_empty
    owner = prototypes.create(repository:, branch_name: "prototype/welcome")
    author = users.octocat
    owner.register!(name: "Welcome", description: "Saved details", start_page: "/welcome", author:)
    build = builds.create_successful(prototype: owner)
    owner.update!(current_build: build)
    retained = owner.attributes.except("replica", "registered_at", "updated_at")

    repository.update!(default_branch: owner.branch_name)

    assert_equal retained, owner.reload.attributes.except("replica", "registered_at", "updated_at")
    assert_predicate owner, :replica?
    assert_nil owner.registered_at
    assert_equal build, owner.builds.sole
    assert_not owner.reviewable?
    assert_predicate repository.prototypes.find_by!(branch_name: "main"), :replica?
  end
end
