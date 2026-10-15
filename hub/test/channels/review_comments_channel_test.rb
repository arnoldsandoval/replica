require "test_helper"

class ReviewCommentsChannelTest < ActionCable::Channel::TestCase
  setup do
    github_app_configurations.create_installed
    stub_github_installation_token
    @user = users.create
    @repository = repositories.create
    @prototype = prototypes.create(repository: @repository)
    @repository_payload = {
      "id" => @repository.github_id,
      "full_name" => @repository.name_with_owner,
      "default_branch" => @repository.default_branch
    }
    stub_github_permissions \
      [ @repository_payload ],
      { @repository.github_id => "pull" }
    @browser_session = @user.sessions.create!
    stub_connection current_user: @user, canvas_grant_id: nil,
      browser_session_id: @browser_session.id, credential_active?: true
  end

  test "streams invalidations for an authorized Prototype" do
    subscribe \
      repositoryGithubId: @repository.github_id,
      prototypeId: @prototype.id

    assert subscription.confirmed?
    assert_has_stream_for @prototype
  end

  test "ended browser credentials deny new subscriptions even while GitHub access remains" do
    stub_connection current_user: @user, canvas_grant_id: nil, credential_active?: false
    subscribe repositoryId: @repository.route_id, prototypeId: @prototype.id
    assert subscription.rejected?
    assert_no_streams
  end

  test "ended credentials cannot receive live notices and periodic checks close the connection" do
    active = true
    closed = false
    connection.define_singleton_method(:credential_active?) { active }
    connection.define_singleton_method(:close) { closed = true }
    subscribe repositoryId: @repository.route_id, prototypeId: @prototype.id
    assert subscription.confirmed?
    handler = subscription.send \
      :stream_handler, "test", ->(message) { subscription.send(:transmit_review_notice, message) },
      coder: ActiveSupport::JSON
    handler.call({ type: "review_comments_changed" }.to_json)
    assert_equal 1, transmissions.length
    active = false
    handler.call({ type: "review_comments_changed" }.to_json)
    assert_equal 1, transmissions.length
    assert closed
    closed = false
    subscription.send(:verify_connection_access)
    assert closed
  end

  test "a subscription waiting on GitHub cannot stream after its Session ends" do
    actor = @user
    actor.update!(hub_admin: true)
    browser_session = @browser_session
    browser_session.update!(fresh_authorized_at: Time.current)
    connection.define_singleton_method(:credential_active?) { Session.exists?(browser_session.id) }
    stub_request(
      :get, "#{GITHUB_API_URL}/repos/#{@repository.name_with_owner}/collaborators/#{@user.login}/permission"
    ).to_return do
      SessionRevocation.end_all!(actor:, browser_session:)
      { status: 200, body: { permission: "pull", user: { id: actor.github_id } }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end

    subscribe repositoryId: @repository.route_id, prototypeId: @prototype.id

    assert subscription.rejected?
    assert_no_streams
  end

  test "periodic canvas checks close a grant revoked during GitHub verification" do
    grant = CanvasGrant.create! \
      user: @user, repository: @repository, token_digest: Digest::SHA256.hexdigest("periodic"),
      expires_at: 7.days.from_now
    stub_connection current_user: @user, canvas_grant_id: grant.id
    connection.define_singleton_method(:credential_active?) { CanvasGrant.authenticated.exists?(grant.id) }
    closed = false
    connection.define_singleton_method(:close) { closed = true }
    subscribe repositoryId: @repository.route_id, prototypeId: @prototype.id
    assert subscription.confirmed?
    stub_request(
      :get, "#{GITHUB_API_URL}/repos/#{@repository.name_with_owner}/collaborators/#{@user.login}/permission"
    ).to_return do
      grant.update!(revoked_at: Time.current)
      { status: 200, body: { permission: "pull", user: { id: @user.github_id } }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end
    subscription.send(:verify_connection_access)

    assert closed
  end

  test "rejects default and former default Build owners" do
    @repository.update!(default_branch: @prototype.branch_name)
    @repository.update!(default_branch: "trunk")
    subscribe repositoryId: @repository.route_id, prototypeId: @prototype.id

    assert subscription.rejected?
    assert_no_streams
  end

  test "streams invalidations using the repository route identity" do
    subscribe \
      repositoryId: @repository.route_id,
      prototypeId: @prototype.id

    assert subscription.confirmed?
    assert_has_stream_for @prototype
  end

  test "limits a paired extension subscription to its granted repository" do
    grant = CanvasGrant.create! \
      user: @user,
      repository: @repository,
      token_digest: Digest::SHA256.hexdigest("channel-test"),
      expires_at: 7.days.from_now
    stub_connection current_user: @user, canvas_grant_id: grant.id, credential_active?: true
    subscribe repositoryId: @repository.route_id, prototypeId: @prototype.id
    assert subscription.confirmed?

    other = repositories.create github_id: 2_002, name_with_owner: "github/other"
    prototype = prototypes.create repository: other
    subscribe repositoryId: other.route_id, prototypeId: prototype.id
    assert subscription.rejected?
    assert_no_streams
  end

  test "streams local repository reviews without a GitHub identity" do
    original_enabled = LocalDevelopment.method(:enabled?)
    original_available = LocalDevelopment.method(:repository_available?)
    LocalDevelopment.define_singleton_method(:enabled?) { true }
    LocalDevelopment.define_singleton_method(:repository_available?) { |_path, **| true }
    user = User.local_developer!
    repository = Repository.create! \
      local_path: Rails.root.join("storage/local-channel-test").to_s,
      local_identity: SecureRandom.uuid,
      name_with_owner: "local/channel",
      default_branch: "main",
      synchronized_at: Time.current
    prototype = prototypes.create(repository:)
    stub_connection current_user: user, canvas_grant_id: nil, credential_active?: true

    subscribe repositoryId: repository.route_id, prototypeId: prototype.id

    assert subscription.confirmed?
    assert_has_stream_for prototype
  ensure
    LocalDevelopment.define_singleton_method(:enabled?, original_enabled)
    LocalDevelopment.define_singleton_method(:repository_available?, original_available)
  end

  test "rejects a Prototype outside the named repository" do
    other_repository = repositories.create \
      github_id: 2_002,
      name_with_owner: "github/other"
    other_prototype = prototypes.create(repository: other_repository)

    subscribe \
      repositoryGithubId: @repository.github_id,
      prototypeId: other_prototype.id

    assert subscription.rejected?
    assert_no_streams
  end

  test "rejects unavailable repository access" do
    Rails.cache.clear
    stub_github_permissions \
      [ @repository_payload ],
      { @repository.github_id => nil }

    subscribe \
      repositoryGithubId: @repository.github_id,
      prototypeId: @prototype.id

    assert subscription.rejected?
    assert_no_streams
  end

  test "rejects when GitHub cannot confirm repository access" do
    Rails.cache.clear
    stub_github_permissions \
      [ @repository_payload ],
      { @repository.github_id => :failure }

    subscribe \
      repositoryGithubId: @repository.github_id,
      prototypeId: @prototype.id

    assert subscription.rejected?
    assert_no_streams
  end

  test "rejects malformed subscription identifiers" do
    subscribe \
      repositoryGithubId: @repository.github_id.to_s,
      prototypeId: @prototype.id

    assert subscription.rejected?
    assert_no_streams
  end
end
