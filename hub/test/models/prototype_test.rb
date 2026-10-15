require "test_helper"

class PrototypeTest < ActiveSupport::TestCase
  test "default publication never creates prototype analytics or public shares" do
    SharingSetting.create!(id: 1, public_sharing_enabled: true)
    github_app_configurations.create_installed
    repository = repositories.create
    owner = prototypes.create(repository:, branch_name: "main")
    build = builds.create_successful(prototype: owner)
    user = users.create

    assert_nil owner.reload.first_published_at
    assert_empty repository.analytics_events
    assert_raises(ActiveRecord::RecordNotFound) { owner.register!(name: "Internal") }
    assert_not owner.register_automatically!(commit_sha: build.commit_sha, author: user)
    assert_not owner.share_links_manageable_by?(user, repository_permission: "admin")
    assert_raises(ActiveRecord::RecordInvalid) do
      ShareLink.create_public!(prototype: owner, build:, created_by: user, label: "Internal")
    end
  end

  test "a registered branch becoming default loses registration and stays internal after another rename" do
    repository = repositories.create
    prototype = prototypes.create(repository:, branch_name: "prototype/welcome")
    prototype.register!(name: "Welcome", start_page: "/settings")
    repository.update!(default_branch: prototype.branch_name)
    assert_predicate prototype.reload, :replica?
    assert_nil prototype.registered_at
    assert_equal "/", prototype.preview_start_page
    repository.update!(default_branch: "trunk")
    assert_not prototype.reload.reviewable?
    assert_not repository.reviewable_prototypes.exists?(id: prototype.id)
    prototype.replica = false
    assert_not prototype.valid?
  end

  test "normalizes start pages and preserves them through partial metadata edits" do
    prototype = prototypes.create
    prototype.register!(name: "Welcome", start_page: " settings?tab=profile#details ")
    assert_equal "/settings?tab=profile#details", prototype.reload.start_page

    prototype.register!(description: "Updated")
    assert_equal "/settings?tab=profile#details", prototype.reload.start_page

    prototype.register!(start_page: " ")
    assert_nil prototype.reload.start_page
    assert_equal "Welcome", prototype.name
  end

  test "extracts routes from this prototype's signed-in and public preview URLs" do
    prototype = prototypes.create
    build = builds.create_successful(prototype:)
    [ PreviewOrigin.current, SharePreviewOrigin.current ].each do |origin|
      prototype.register!(name: "Welcome", start_page: "#{origin.url(build.id)}settings?q=a%20b#details")
      assert_equal "/settings?q=a%20b#details", prototype.reload.start_page
    end
  end

  test "rejects unrelated URLs and unsafe routes without changing saved metadata" do
    prototype = prototypes.create
    other = prototypes.create(repository: prototype.repository, branch_name: "prototype/other")
    build = builds.create_successful(prototype: other)
    prototype.register!(name: "Welcome", start_page: "/welcome")
    [
      "https://example.com/settings",
      PreviewOrigin.current.url(build.id),
      "//example.com/settings", "javascript:alert(1)", "/\\example.com",
      "/settings\nheader", "/settings\tvalue", "/%0aheader",
      "/%FF", "/%C3%28", "/%E2%82",
      "/../settings", "/a/%2e%2e//example.com", "/%2fexample.com", "/%5cexample.com",
      "/__replica", "/__replica/authorize", "/%5f_replica/authorize",
      "/#{'a' * 2048}"
    ].each do |start_page|
      assert_raises(ActiveRecord::RecordInvalid, start_page) do
        prototype.register!(name: "Changed", start_page:)
      end
      assert_equal "/welcome", prototype.reload.start_page
      assert_equal "Welcome", prototype.name
    end
  end

  test "rejects credentials and mismatched ports or schemes on an owned preview" do
    prototype = prototypes.create
    build = builds.create_successful(prototype:)
    url = URI.parse(PreviewOrigin.current.url(build.id))
    [ "#{url.scheme}://user:secret@#{url.host}:#{url.port}/",
      "#{url.scheme}://#{url.host}:#{url.port + 1}/",
      "https://#{url.host}:#{url.port}/" ].each do |start_page|
      assert_not prototype.update(start_page:), start_page
      assert prototype.errors[:start_page].present?
    end
  end

  test "accepts query and hash routes and the exact start-page size limit" do
    prototype = prototypes.create
    { "?tab=profile#details" => "/?tab=profile#details", "#/welcome" => "/#/welcome",
      "/hello%20world" => "/hello%20world", "/" + "a" * 2047 => "/" + "a" * 2047 }.each do |input, expected|
      prototype.update!(start_page: input)
      assert_equal expected, prototype.reload.start_page
    end
  end

  test "identifies one prototype by repository and branch" do
    prototype = prototypes.create

    duplicate = prototypes.new(repository: prototype.repository, branch_name: prototype.branch_name)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:branch_name], "has already been taken"
  end

  test "does not allow branch identity to change" do
    prototype = prototypes.create

    assert_not prototype.update(branch_name: "prototype/renamed")
    assert_includes prototype.errors[:branch_name], "cannot change"
  end

  test "registers a branch with a name and optional description" do
    prototype = prototypes.create

    prototype.register!(name: "  Welcome  ", description: "  Try the new flow  ")

    assert_equal "Welcome", prototype.reload.name
    assert_equal "Try the new flow", prototype.description
    assert prototype.registered?
    assert_includes Prototype.registered, prototype
    assert_not_includes Prototype.unregistered, prototype
  end

  test "keeps registration when editing its metadata" do
    prototype = prototypes.create
    prototype.register!(name: "Welcome", description: "First version")
    registered_at = prototype.registered_at

    prototype.register!(name: "Updated", description: "")

    assert_equal "Updated", prototype.reload.name
    assert_nil prototype.description
    assert_equal registered_at, prototype.registered_at
  end

  test "registration-only reloads a stale instance and preserves the first registration" do
    prototype = prototypes.create
    stale = Prototype.find(prototype.id)
    first_author = users.create
    later_writer = users.create(github_id: 10_002, login: "another-writer")
    prototype.register! \
      name: "Custom",
      description: "Saved elsewhere",
      start_page: "/custom?step=2#intro",
      author: first_author
    saved = prototype.reload.attributes

    assert_no_difference -> { Analytics::Event.where(name: "prototype_registered").count } do
      stale.register! \
        name: stale.branch_name,
        description: "Stale details",
        start_page: "/stale",
        author: later_writer,
        registration_only: true
    end

    assert_equal saved, prototype.reload.attributes
    assert_equal first_author, prototype.author
  end

  test "registration-only checks for another registrant after acquiring the repository lock" do
    prototype = prototypes.create
    repository = prototype.repository
    original_lock = repository.method(:with_lock)
    first_author = users.create
    later_writer = users.create(github_id: 10_002, login: "another-writer")
    saved = nil
    repository.define_singleton_method(:with_lock) do |&block|
      winner = Prototype.find(prototype.id)
      winner.register! \
        name: "First title",
        description: "First details",
        start_page: "/first",
        author: first_author
      saved = winner.reload.attributes
      original_lock.call(&block)
    end

    assert_difference -> { Analytics::Event.where(name: "prototype_registered").count }, 1 do
      prototype.register!(name: prototype.branch_name, author: later_writer, registration_only: true)
    end

    assert_not_nil saved
    assert_equal saved, prototype.reload.attributes
    assert_equal first_author, prototype.author
  end

  test "automatic registration waits for the latest successful Build and keeps saved metadata" do
    prototype = prototypes.create \
      name: "Saved title",
      description: "Saved description",
      start_page: "/settings?tab=profile#details"
    start_page_set_at = prototype.start_page_set_at
    author = users.create
    assert_not prototype.register_automatically!(commit_sha: nil, author: author)
    build = builds.create(prototype:)
    assert_not prototype.register_automatically!(commit_sha: build.commit_sha, author: author)
    successful = builds.create_successful(prototype:, number: 2, commit_sha: "b" * 40)
    assert_not prototype.register_automatically!(commit_sha: build.commit_sha, author: author)
    assert prototype.register_automatically!(commit_sha: successful.commit_sha, author: author)
    assert_equal "Saved title", prototype.reload.name
    assert_equal "Saved description", prototype.description
    assert_equal "/settings?tab=profile#details", prototype.start_page
    assert_equal start_page_set_at, prototype.start_page_set_at
    assert_equal author, prototype.author
  end

  test "automatic registration does not overwrite a registration saved through another instance" do
    prototype = prototypes.create
    stale = Prototype.find(prototype.id)
    prototype.register!(name: "Custom", description: "Saved elsewhere")

    assert stale.register_automatically!(commit_sha: "a" * 40, author: users.create)

    assert_equal "Custom", prototype.reload.name
    assert_equal "Saved elsewhere", prototype.description
    assert_nil prototype.author
  end

  test "keeps the first registrant as author through later edits" do
    prototype = prototypes.create
    registrant = users.create
    later_writer = users.create(github_id: 10_002, login: "another-writer")

    prototype.register!(name: "Welcome", author: registrant)
    assert_equal registrant, prototype.reload.author

    prototype.register!(name: "Updated", author: later_writer)
    assert_equal registrant, prototype.reload.author

    older_prototype = prototypes.create(repository: prototype.repository, branch_name: "prototype/older")
    older_prototype.register!(name: "Older")
    older_prototype.register!(name: "Edited", author: later_writer)
    assert_nil older_prototype.reload.author
  end

  test "partial edits preserve the other metadata field" do
    prototype = prototypes.create
    prototype.register!(name: "Welcome", description: "First version")

    prototype.register!(name: "Updated")
    assert_equal "First version", prototype.reload.description

    prototype.register!(description: "Second version")
    assert_equal "Updated", prototype.reload.name

    prototype.register!(description: "")
    assert_nil prototype.reload.description
  end

  test "direct saves reject metadata the database cannot accept" do
    prototype = prototypes.create

    assert_not prototype.update(name: " ")
    assert_includes prototype.errors[:name], "can't be blank"
    assert_not prototype.update(description: " ")
    assert_includes prototype.errors[:description], "can't be blank"
    assert_not prototype.update(name: "x" * 256)
    assert_includes prototype.errors[:name], "is too long (maximum is 255 characters)"
  end

  test "registers with a name when no description is provided" do
    prototype = prototypes.create

    prototype.register!(name: "Welcome")

    assert prototype.reload.registered?
    assert_nil prototype.description
  end

  test "does not register a branch without a name" do
    prototype = prototypes.create

    assert_raises(ActiveRecord::RecordInvalid) do
      prototype.register!(name: " ", description: "No title")
    end

    assert_not prototype.reload.registered?
    assert_nil prototype.name
  end

  test "does not register a branch with an oversized description" do
    prototype = prototypes.create

    assert_raises(ActiveRecord::RecordInvalid) do
      prototype.register!(name: "Welcome", description: "x" * 501)
    end

    assert_not prototype.reload.registered?
  end
end
