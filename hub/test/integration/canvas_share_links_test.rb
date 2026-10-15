require "test_helper"
require_relative "../support/share_link_lifetime_helpers"

class CanvasShareLinksTest < ActionDispatch::IntegrationTest
  include ShareLinkLifetimeHelpers
  setup do
    SharingSetting.create!(id: 1, public_sharing_enabled: true)
    host! "replica.localhost:19500"
    github_app_configurations.create_installed
    @repository_payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ @repository_payload ], permissions: { 2001 => "pull" })
    sign_in
    @user = User.find_by!(github_id: 1001)
    @repository = Repository.find_by!(github_id: 2001)
    @prototype = prototypes.create(repository: @repository)
    @build = builds.create_successful \
      prototype: @prototype,
      commit_author_name: "The Octocat",
      commit_author_github_id: @user.github_id,
      commit_author_login: @user.login,
      commit_author_checked_at: Time.current
    token = "rp_#{SecureRandom.urlsafe_base64(32)}"
    @grant = CanvasGrant.create! \
      user: @user,
      repository: @repository,
      token_digest: Digest::SHA256.hexdigest(token),
      expires_at: 7.days.from_now
    @headers = { "Authorization" => "Bearer #{token}" }
    @path = canvas_api_share_links_path(@repository.route_id, @prototype)
    delete session_path
  end

  test "disabled sharing blocks list and direct mutations without a fresh challenge" do
    SharingSetting.first.update!(public_sharing_enabled: false)
    assert_no_difference [ "ShareLink.count", "FreshAuthorization.count" ] do
      create_link(expiration: "never")
      assert_response :forbidden
      assert_equal "public_sharing_disabled", JSON.parse(response.body).fetch("code")
      get @path, headers: @headers
      assert_response :forbidden
      delete "#{@path}/1", headers: @headers
      assert_response :forbidden
    end
    get canvas_api_prototype_path, params: { branch: @prototype.branch_name }, headers: @headers
    assert_response :success
    assert_equal false, JSON.parse(response.body).fetch("publicSharingEnabled")
    assert_equal true, JSON.parse(response.body).fetch("canManageShareLinks")
  end

  test "creator access changing during verification returns a stable denial without disabling sharing" do
    original = Repository::Authorization.instance_method(:permission_for)
    Repository::Authorization.define_method(:permission_for) do |user, **options|
      result = original.bind_call(self, user, **options)
      ShareLinkCreatorRevocation.confirm_loss!(repository: record, user:) if options[:fresh]
      result
    end
    assert_no_difference [ "ShareLink.count", "FreshAuthorization.count" ] do
      create_link
    end
    assert_response :forbidden
    assert_equal({
      "code" => "creator_access_changed",
      "errors" => [ I18n.t("share_links.access_changed") ]
    }, JSON.parse(response.body))
    assert SharingSetting.enabled?
    assert_equal "denied", SecurityAuditEvent.where(action: "share_link.create").last.outcome
  ensure
    Repository::Authorization.define_method(:permission_for, original) if original
  end

  test "returns a public URL and default expiry for a Build author with only read access" do
    travel_to Time.current.change(usec: 0) do
      assert_difference "ShareLink.count", 1 do
        create_link(label: "  Usability review  ")
      end

      assert_response :created
      assert_equal "application/json", response.media_type
      assert_nil response.headers["Location"]
      assert_equal "private, no-store", response.headers["Cache-Control"]
      link = ShareLink.last
      assert_equal @user, link.created_by
      assert_equal @build, link.build
      assert_equal @prototype, link.prototype
      assert_equal 7.days.from_now, link.expires_at
      assert_equal({
        "id" => link.id,
        "url" => "#{Rails.configuration.x.hub_origin.delete_suffix('/')}#{shared_build_path(link.public_id)}",
        "buildNumber" => @build.number,
        "label" => "Usability review",
        "expiresAt" => link.expires_at.iso8601
      }, JSON.parse(response.body))
    end
  end

  test "supports each permitted expiry choice with a thirty day maximum" do
    with_share_link_maximum_lifetime(30.days) do
      travel_to Time.current.change(usec: 0) do
        ShareLink.expiration_options.each do |expiration, duration|
          create_link(expiration:)

          assert_response :created
          expected = (Time.current + duration).iso8601
          assert_equal expected, JSON.parse(response.body).fetch("expiresAt")
          assert_equal expected, ShareLink.last.expires_at.iso8601
        end
      end
    end
  end

  test "default sharing reports allowed choices and rejects long lived links without a challenge" do
    assert_equal 7.days, Rails.configuration.x.share_link_maximum_lifetime
    with_share_link_maximum_lifetime(7.days) do
      get canvas_api_prototype_path, params: { branch: @prototype.branch_name }, headers: @headers
      assert_response :success
      assert_equal %w[one_day seven_days],
        JSON.parse(response.body).fetch("shareLinkExpirationOptions")
      %w[never thirty_days].each do |expiration|
        assert_no_difference [ "ShareLink.count", "FreshAuthorization.count" ] do
          create_link(expiration:)
        end
        assert_response :unprocessable_entity
        assert_includes JSON.parse(response.body).fetch("errors").first, "share-link policy"
      end
      [ nil, "one_day", "seven_days" ].each do |expiration|
        create_link(**(expiration ? { expiration: } : {}))
        assert_response :created
        link = ShareLink.last
        assert_equal link.created_at + ShareLink.expiration_duration(expiration), link.expires_at
      end
    end
  end

  test "configured active lists omit old links and report the capped deadline for retained links" do
    retained, old = with_share_link_maximum_lifetime(nil) do
      [
        ShareLink.create_public!(prototype: @prototype, build: @build, created_by: @user,
          label: "Retained", expiration: "never"),
        ShareLink.create_public!(prototype: @prototype, build: @build, created_by: @user,
          label: "Too old", expiration: "thirty_days")
      ]
    end
    old.update_column(:created_at, 8.days.ago)
    with_share_link_maximum_lifetime(7.days) do
      get @path, headers: @headers
      assert_response :success
      links = JSON.parse(response.body).fetch("shareLinks")
      assert_equal [ retained.id ], links.map { |link| link.fetch("id") }
      assert_equal (retained.created_at + 7.days).iso8601, links.first.fetch("expiresAt")
    end
  end

  test "lets administrators share without Build authorship" do
    @build.update_columns(commit_author_github_id: 1_002)
    stub_github_permissions([ @repository_payload ], { 2001 => "admin" })

    create_link

    assert_response :created
  end

  test "denies readers and writers without Build authorship" do
    @build.update_columns(commit_author_github_id: 1_002)
    [ "pull", "push" ].each do |permission|
      stub_github_permissions([ @repository_payload ], { 2001 => permission })

      assert_no_difference "ShareLink.count" do
        create_link
      end
      assert_response :not_found
    end
  end

  test "rechecks current access for every creation" do
    create_link
    assert_response :created
    stub_github_permissions([ @repository_payload ], { 2001 => nil })

    assert_no_difference "ShareLink.count" do
      create_link
    end
    assert_response :forbidden
  end

  test "does not accept a browser session instead of a bearer token" do
    sign_in
    [ {}, { "Authorization" => "Bearer invalid" } ].each do |headers|
      @headers = headers
      assert_no_difference "ShareLink.count" do
        create_link
      end
      assert_response :unauthorized
    end
  end

  test "rejects revoked and expired grants" do
    @grant.revoke!
    assert_no_difference "ShareLink.count" do
      create_link
    end
    assert_response :unauthorized

    @grant.update_columns(revoked_at: nil, created_at: 2.days.ago, expires_at: 1.day.ago)
    assert_no_difference "ShareLink.count" do
      create_link
    end
    assert_response :unauthorized
  end

  test "cannot escape the grant repository" do
    @path = canvas_api_share_links_path(@repository.route_id + 1, @prototype)

    assert_no_difference "ShareLink.count" do
      create_link
    end
    assert_response :not_found
  end

  test "rejects Builds outside the authorized Prototype and unfinished Builds" do
    other = prototypes.create(repository: @repository, branch_name: "prototype/other")
    builds.create_successful(prototype: other, number: 2)
    builds.create(prototype: @prototype, number: 3, commit_sha: "c" * 40)
    [ 2, 3, 0, -1, "1oops" ].each do |number|
      assert_no_difference "ShareLink.count" do
        create_link(build_number: number)
      end
      assert_response :not_found
      assert JSON.parse(response.body).fetch("errors").any?
    end
  end

  test "rejects default-branch sharing" do
    default_branch = prototypes.create(repository: @repository, branch_name: @repository.default_branch)
    @path = canvas_api_share_links_path(@repository.route_id, default_branch)

    assert_no_difference "ShareLink.count" do
      create_link
    end
    assert_response :not_found
  end

  test "returns validation errors without saving a partial link" do
    [ { expiration: "invalid" }, { label: "" }, { label: "a" * 101 } ].each do |attributes|
      assert_no_difference "ShareLink.count" do
        create_link(**attributes)
      end
      assert_response :unprocessable_entity
      assert JSON.parse(response.body).fetch("errors").any?
      assert_nil response.headers["Location"]
    end
  end

  test "returns unavailable when GitHub cannot verify access" do
    stub_github_permissions([ @repository_payload ], { 2001 => :failure })

    assert_no_difference "ShareLink.count" do
      create_link
    end
    assert_response :service_unavailable
  end

  test "lists all active links across Builds newest first without browser credentials" do
    older = ShareLink.create_public! \
      prototype: @prototype,
      build: @build,
      created_by: @user,
      label: "Earlier",
      expiration: "seven_days"
    newer_build = builds.create_successful(prototype: @prototype, number: 2, commit_sha: "b" * 40)
    newer = ShareLink.create_public! \
      prototype: @prototype,
      build: newer_build,
      created_by: @user,
      label: "Newer"
    expired = ShareLink.create_public! \
      prototype: @prototype,
      build: @build,
      created_by: @user,
      label: "Expired"
    expired.update_columns(created_at: 2.days.ago, expires_at: 1.day.ago)

    get @path, headers: @headers, as: :json

    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    page = JSON.parse(response.body)
    assert_equal [ newer.id, older.id ], page.fetch("shareLinks").map { |link| link.fetch("id") }
    assert_equal [ 2, 1 ], page.fetch("shareLinks").map { |link| link.fetch("buildNumber") }
    assert_equal @user.login, page.fetch("shareLinks").first.fetch("createdBy").fetch("login")
    assert_equal older.expires_at.iso8601, page.fetch("shareLinks").last.fetch("expiresAt")
    assert_equal false, page.fetch("hasMore")
    assert_nil page.fetch("nextCursor")
  end

  test "paginates same-time links without gaps and rejects invalid or other-Prototype cursors" do
    travel_to Time.current.change(usec: 0) do
      links = 27.times.map do |index|
        ShareLink.create_public! \
          prototype: @prototype,
          build: @build,
          created_by: @user,
          label: "Link #{index}"
      end
      get @path, headers: @headers, as: :json
      assert_response :success
      page = JSON.parse(response.body)
      assert_equal links.reverse.first(25).map(&:id), page.fetch("shareLinks").map { |link| link.fetch("id") }
      cursor = page.fetch("nextCursor")
      get @path, params: { cursor: }, headers: @headers, as: :json
      assert_response :success
      assert_equal links.reverse.last(2).map(&:id), JSON.parse(response.body).fetch("shareLinks").map { |link| link.fetch("id") }

      other = prototypes.create(repository: @repository, branch_name: "prototype/other")
      builds.create_successful \
        prototype: other,
        commit_author_github_id: @user.github_id,
        commit_author_login: @user.login,
        commit_author_name: @user.name,
        commit_author_checked_at: Time.current
      get canvas_api_share_links_path(@repository.route_id, other),
        params: { cursor: }, headers: @headers, as: :json
      assert_response :bad_request
      get @path, params: { cursor: [ "invalid" ] }, headers: @headers, as: :json
      assert_response :bad_request
      get @path, params: { cursor: "tampered" }, headers: @headers, as: :json
      assert_response :bad_request
    end
  end

  test "deletes only a link under this Prototype and revokes its public route" do
    create_link
    link = ShareLink.last
    delete canvas_api_share_link_path(@repository.route_id, @prototype, link), headers: @headers
    assert_response :no_content
    assert_not ShareLink.exists?(link.id)
    get shared_build_path(link.public_id)
    assert_response :not_found

    other = prototypes.create(repository: @repository, branch_name: "prototype/other")
    other_build = builds.create_successful(prototype: other)
    foreign = ShareLink.create_public! \
      prototype: other,
      build: other_build,
      created_by: @user,
      label: "Other"
    assert_no_difference "ShareLink.count" do
      delete canvas_api_share_link_path(@repository.route_id, @prototype, foreign), headers: @headers
    end
    assert_response :not_found
    assert_equal \
      [ "The share link was not found. Refresh links to see the active list." ],
      JSON.parse(response.body).fetch("errors")
  end

  test "returns a link-specific refresh instruction when a link has already been deleted" do
    create_link
    link = ShareLink.last
    link.destroy!

    delete canvas_api_share_link_path(@repository.route_id, @prototype, link), headers: @headers

    assert_response :not_found
    assert_equal \
      [ "The share link was not found. Refresh links to see the active list." ],
      JSON.parse(response.body).fetch("errors")
  end

  test "returns a link-specific refresh instruction after expiration cleanup" do
    create_link
    link = ShareLink.last
    link.update_columns(created_at: 2.days.ago, expires_at: 1.day.ago)
    assert_difference "ShareLink.count", -1 do
      ShareLink.clear_expired!
    end

    assert_no_difference "ShareLink.count" do
      delete canvas_api_share_link_path(@repository.route_id, @prototype, link), headers: @headers
    end

    assert_response :not_found
    assert_equal \
      [ "The share link was not found. Refresh links to see the active list." ],
      JSON.parse(response.body).fetch("errors")
  end

  test "returns a link-specific refresh instruction for a nonexistent link ID" do
    create_link
    missing_id = ShareLink.maximum(:id) + 1

    assert_no_difference "ShareLink.count" do
      delete canvas_api_share_link_path(@repository.route_id, @prototype, missing_id), headers: @headers
    end

    assert_response :not_found
    assert_equal \
      [ "The share link was not found. Refresh links to see the active list." ],
      JSON.parse(response.body).fetch("errors")
  end

  test "keeps the target-specific error when the Prototype is missing" do
    create_link
    link = ShareLink.last
    missing_id = Prototype.maximum(:id) + 1

    assert_no_difference "ShareLink.count" do
      delete canvas_api_share_link_path(@repository.route_id, missing_id, link), headers: @headers
    end

    assert_response :not_found
    assert_equal \
      [ "The requested Prototype or successful Build was not found." ],
      JSON.parse(response.body).fetch("errors")
  end

  test "rechecks deletion permissions and denies writers without authorship" do
    create_link
    link = ShareLink.last
    @build.update_columns(commit_author_github_id: 1_002)
    stub_github_permissions([ @repository_payload ], { 2001 => "push" })
    get @path, headers: @headers, as: :json
    assert_response :not_found
    assert_no_difference "ShareLink.count" do
      delete canvas_api_share_link_path(@repository.route_id, @prototype, link), headers: @headers
    end
    assert_response :not_found
    stub_github_permissions([ @repository_payload ], { 2001 => "admin" })
    delete canvas_api_share_link_path(@repository.route_id, @prototype, link), headers: @headers
    assert_response :no_content
  end

  test "metadata reports sharing independently of edit access and latest Build authorship" do
    @prototype.register! name: "Prototype", author: @user
    newer = builds.create_successful(prototype: @prototype, number: 2, commit_sha: "b" * 40)
    newer.update_columns(commit_author_github_id: 1_002, commit_author_login: "mona", commit_author_name: "Mona Lisa")
    get canvas_api_prototype_path, params: { branch: @prototype.branch_name }, headers: @headers, as: :json
    assert_response :success
    metadata = JSON.parse(response.body)
    assert_equal false, metadata.fetch("canEdit")
    assert_equal true, metadata.fetch("canManageShareLinks")
    @build.update_columns(commit_author_github_id: 1_002)
    stub_github_permissions([ @repository_payload ], { 2001 => "push" })
    get canvas_api_prototype_path, params: { branch: @prototype.branch_name }, headers: @headers, as: :json
    assert_response :success
    assert_equal false, JSON.parse(response.body).fetch("canManageShareLinks")
  end

  test "listing and deletion reject revoked and expired bearer grants" do
    create_link
    link = ShareLink.last
    [ { revoked_at: Time.current }, { revoked_at: nil, created_at: 2.days.ago, expires_at: 1.day.ago } ].each do |attributes|
      @grant.update_columns(attributes)
      get @path, headers: @headers, as: :json
      assert_response :unauthorized
      assert_no_difference "ShareLink.count" do
        delete canvas_api_share_link_path(@repository.route_id, @prototype, link), headers: @headers
      end
      assert_response :unauthorized
    end
  end

  private

  def create_link(**attributes)
    post @path,
      params: { share_link: { build_number: @build.number, label: "Review" }.merge(attributes) },
      headers: @headers,
      as: :json
  end

  def sign_in
    sign_in_to_hub
  end
end
