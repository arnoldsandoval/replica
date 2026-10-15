require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "claims the welcome destination only once across stale account instances" do
    user = users.create
    other_browser_user = User.find(user.id)

    assert user.consume_welcome_sign_in!
    assert_not other_browser_user.consume_welcome_sign_in!
    assert_not user.reload.welcome_sign_in_pending?
  end

  test "existing or hidden accounts do not get a welcome redirect" do
    existing = users.create(welcome_sign_in_pending: false)
    hidden = users.create(github_id: 1002, login: "mona", welcome_hidden: true)

    assert_not existing.consume_welcome_sign_in!
    assert_not hidden.consume_welcome_sign_in!
    assert_not hidden.reload.welcome_sign_in_pending?
  end

  test "hiding welcome does not change other accounts" do
    user = users.create
    other = users.create(github_id: 1002, login: "mona")

    user.hide_welcome!
    user.hide_welcome!

    assert user.reload.welcome_hidden?
    assert_not other.reload.welcome_hidden?
  end

  test "admits a stable GitHub identity with an accessible repository" do
    repository = repositories.create

    user = User.admit!(profile, accessible_repository_ids: [ repository.github_id ])

    assert_equal 1001, user.github_id
    assert_equal "renamed-octocat", user.login
    assert user.last_authenticated_at
  end

  test "rejects a user without an accessible installed repository" do
    repositories.create

    assert_raises(User::RepositoryAccessDenied) do
      User.admit!(profile, accessible_repository_ids: [ 9999 ])
    end
    assert_not User.exists?(github_id: 1001)
  end

  test "updates mutable profile data without changing identity" do
    existing = users.create login: "old-login"
    repository = repositories.create

    admitted = User.admit!(profile, accessible_repository_ids: [ repository.github_id ])

    assert_equal existing.id, admitted.id
    assert_equal "renamed-octocat", admitted.login
  end

  private

  def profile
    {
      "id" => 1001,
      "login" => "renamed-octocat",
      "name" => "Octocat",
      "avatar_url" => "https://avatars.example/octocat"
    }
  end
end
