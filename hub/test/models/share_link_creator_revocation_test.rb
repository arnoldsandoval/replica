require "test_helper"

class ShareLinkCreatorRevocationTest < ActiveSupport::TestCase
  setup do
    seed "repositories/github_prototype"
    SharingSetting.create!(id: 1, public_sharing_enabled: true)
    @repository = repositories.github_prototype
    @user = users.octocat
    @link = create_link
    @other = ShareLink.create_public! \
      prototype: prototypes.welcome, build: builds.welcome, created_by: users.mona, label: "Other creator"
    @configuration = GithubAppConfiguration.current
    @configuration.tokens.define_singleton_method(:installation) { "installation-token" }
  end

  test "exact successful none permanently revokes only this creator's repository links" do
    other_repository = repositories.create(github_id: 3001, name_with_owner: "github/another")
    prototype = prototypes.create(repository: other_repository)
    build = builds.create_successful(prototype:)
    elsewhere = ShareLink.create_public!(prototype:, build:, created_by: @user, label: "Elsewhere")
    SharePreviewGrant.issue!(share_link: @link)
    stub_permission(permission: "none", user: { id: @user.github_id })

    assert_equal "none", permission
    assert @link.reload.revoked_at
    assert_not @link.available?
    assert_empty SharePreviewGrant.where(share_link: @link)
    assert @other.reload.available?
    assert elsewhere.reload.available?
    assert_equal 1, ShareLinkCreatorRevocation.proof_for(@repository, @user).revision
    event = SecurityAuditEvent.where(action: "share_link.creator_access_loss").last
    assert_equal @repository.id, event.repository_id
    assert event.repository_scoped?
    assert_equal @user.id, event.user_id
    stub_permission(permission: "read", user: { id: @user.github_id })
    assert_equal "read", permission
    assert_not @link.reload.available?
    assert create_link(authorization_proof: @repository.authorization.share_link_creation_proof).available?
  end

  test "404 mismatched and null identity cannot prove loss" do
    stub_request(:get, permission_url).to_return(status: 404, body: '{"message":"Not Found"}')
    assert_equal "none", permission
    stub_permission(permission: "none", user: { id: @user.github_id + 1 })
    assert_equal "none", permission
    stub_permission(permission: "none", user: nil)
    assert_equal "none", permission
    stub_permission(permission: "none", user: { id: @user.github_id.to_s })
    assert_equal "none", permission
    stub_permission(permission: "none", user: { id: @user.github_id.to_f })
    assert_equal "none", permission
    assert_nil @link.reload.revoked_at
    assert_empty ShareLinkCreatorRevocation.all
  end

  test "cached positive permission delays observation until the next cache miss" do
    cache = ActiveSupport::Cache::MemoryStore.new
    stub_permission(permission: "read", user: { id: @user.github_id })
    assert_equal "read", @repository.authorization.permission_for(@user, configuration: @configuration, cache:)
    stub_permission(permission: "none", user: { id: @user.github_id })

    assert_equal "read", @repository.authorization.permission_for(@user, configuration: @configuration, cache:)
    assert_nil @link.reload.revoked_at
    cache.clear

    assert_equal "none", @repository.authorization.permission_for(@user, configuration: @configuration, cache:)
    assert @link.reload.revoked_at
    assert_not @link.available?
    assert @other.reload.available?
  end

  test "fresh permission bypasses a cached positive result and revokes existing links" do
    cache = ActiveSupport::Cache::MemoryStore.new
    stub_permission(permission: "read", user: { id: @user.github_id })
    assert_equal "read", @repository.authorization.permission_for(@user, configuration: @configuration, cache:)
    stub_permission(permission: "none", user: { id: @user.github_id })

    assert_equal "none", @repository.authorization.permission_for(
      @user, fresh: true, configuration: @configuration, cache:
    )
    assert @link.reload.revoked_at
    assert_not @link.available?
  end

  test "outages rate limits malformed and unknown responses never revoke links" do
    [ 403, 429, 500, 503 ].each do |status|
      stub_request(:get, permission_url).to_return(status:, body: '{"message":"Unavailable"}')
      assert_raises(GithubClient::Error) { permission }
      assert_nil @link.reload.revoked_at
    end
    stub_request(:get, permission_url).to_timeout
    assert_raises(GithubClient::Error) { permission }
    stub_permission(permission: "unknown", user: { id: @user.github_id })
    assert_raises(GithubClient::InvalidResponse) { permission }
    stub_request(:get, permission_url).to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    assert_raises(GithubClient::InvalidResponse) { permission }
    stub_request(:get, permission_url).to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })
    assert_raises(GithubClient::InvalidResponse) { permission }
    assert_nil @link.reload.revoked_at
    assert_empty ShareLinkCreatorRevocation.all
  end

  test "earlier positive permission cannot create after loss even when access returns" do
    stub_permission(permission: "read", user: { id: @user.github_id })
    permission
    earlier = @repository.authorization.share_link_creation_proof
    stub_permission(permission: "none", user: { id: @user.github_id })
    permission
    stub_permission(permission: "read", user: { id: @user.github_id })
    permission
    assert_raises(ShareLinkCreatorRevocation::Changed) { create_link(authorization_proof: earlier) }
    assert_not @link.reload.available?
  end

  private

  def create_link(**extra)
    ShareLink.create_public! \
      prototype: prototypes.welcome, build: builds.welcome, created_by: @user, label: "Creator",
      **extra
  end

  def permission
    @repository.authorization.permission_for(@user, fresh: true, configuration: @configuration)
  end

  def permission_url
    "#{GITHUB_API_URL}/repos/#{@repository.name_with_owner}/collaborators/#{@user.login}/permission"
  end

  def stub_permission(payload)
    stub_request(:get, permission_url).to_return \
      status: 200, body: JSON.generate(payload), headers: { "Content-Type" => "application/json" }
  end
end
