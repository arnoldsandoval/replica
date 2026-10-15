require "test_helper"

class PrototypeIntroductionTest < ActiveSupport::TestCase
  test "records one opening for each user and prototype" do
    user = users.create(github_id: 1001, login: "octocat")
    other_user = users.create(github_id: 1002, login: "mona")
    repository = repositories.create
    prototype = prototypes.create(repository:, branch_name: "prototype/welcome")
    other_prototype = prototypes.create(repository:, branch_name: "prototype/other")

    first = PrototypeIntroduction.record!(user:, prototype:)
    assert first.previously_new_record?
    assert_not PrototypeIntroduction.record!(user:, prototype:).previously_new_record?
    assert PrototypeIntroduction.record!(user: other_user, prototype:).previously_new_record?
    assert PrototypeIntroduction.record!(user:, prototype: other_prototype).previously_new_record?
    assert_equal 3, PrototypeIntroduction.count
  end

  test "enforces uniqueness and deletes introductions with their prototype or user" do
    user = users.create
    prototype = prototypes.create
    PrototypeIntroduction.record!(user:, prototype:)

    assert_raises ActiveRecord::RecordNotUnique do
      PrototypeIntroduction.create!(user:, prototype:)
    end

    prototype.destroy!
    assert_empty user.prototype_introductions

    other_prototype = prototypes.create(repository: prototype.repository, branch_name: "prototype/other")
    PrototypeIntroduction.record!(user:, prototype: other_prototype)
    user.destroy!
    assert_empty other_prototype.prototype_introductions
  end
end
