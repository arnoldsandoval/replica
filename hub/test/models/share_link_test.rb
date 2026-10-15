require "test_helper"
require_relative "../support/share_link_lifetime_helpers"

class ShareLinkTest < ActiveSupport::TestCase
  include ShareLinkLifetimeHelpers
  setup do
    SharingSetting.create!(id: 1, public_sharing_enabled: true)
    seed "repositories/github_prototype"
    @repository = repositories.github_prototype
    @prototype = prototypes.welcome
    @build = builds.welcome
    @creator = users.octocat
  end

  test "creates a public link for one successful Build" do
    travel_to Time.current.change(usec: 0) do
      link = ShareLink.create_public! \
        prototype: @prototype,
        build: @build,
        created_by: @creator,
        label: "Design review",
        expiration: "seven_days"

      assert_match ShareLink::PUBLIC_ID_FORMAT, link.public_id
      assert_equal "Design review", link.label
      assert_equal 7.days.from_now, link.expires_at
      assert link.available?
    end
  end

  test "can represent a legacy link without expiration" do
    link = create_legacy_link(expiration: "never")
    assert_nil link.expires_at
    assert link.available?
  end

  test "enforces the seven day default maximum" do
    assert_equal 7.days, Rails.configuration.x.share_link_maximum_lifetime
    assert_equal %w[one_day seven_days], ShareLink.expiration_options.keys
    assert_equal "seven_days", ShareLink.default_expiration
    %w[never thirty_days].each do |expiration|
      assert_raises(ShareLink::InvalidExpiration) { create_link(expiration:) }
    end
  end

  test "limits configured creation choices and direct model writes" do
    with_share_link_maximum_lifetime(7.days) do
      assert_equal %w[one_day seven_days], ShareLink.expiration_options.keys
      [ nil, "", "one_day", "seven_days" ].each do |expiration|
        link = create_link(expiration:)
        assert_equal link.created_at + ShareLink.expiration_duration(expiration), link.expires_at
      end
      %w[never thirty_days invalid].each do |expiration|
        assert_raises(ShareLink::InvalidExpiration) { create_link(expiration:) }
      end
      [ nil, 30.days.from_now ].each do |expires_at|
        link = ShareLink.new(prototype: @prototype, build: @build, created_by: @creator,
          label: "Direct", expires_at:)
        assert_not link.valid?
        assert_includes link.errors[:expires_at], "must be within 7 days of creation"
      end
      link = create_link
      assert_not link.update(expires_at: 30.days.from_now)
      assert_includes link.errors[:expires_at], "must be within 7 days of creation"
      time = Time.current
      assert_not link.reload.update(created_at: time + 1.day, expires_at: time + 8.days)
      assert_includes link.errors[:created_at], "cannot change"
    end
  end

  test "uses a permitted default when the deployment maximum is one day" do
    with_share_link_maximum_lifetime(1.day) do
      assert_equal %w[one_day], ShareLink.expiration_options.keys
      assert_equal "one_day", ShareLink.default_expiration
      link = create_link
      assert_equal link.created_at + 1.day, link.expires_at
    end
  end

  test "bounds existing never and long lived links at the exact creation time deadline" do
    travel_to Time.current.change(usec: 123456), with_usec: true do
      links = %w[never thirty_days].map { |expiration| create_legacy_link(expiration:) }
      with_share_link_maximum_lifetime(7.days) do
        links.each do |link|
          deadline = link.created_at + 7.days
          assert_equal deadline, link.effective_expires_at
          assert link.available?(time: deadline - 0.000001)
          assert_not link.available?(time: deadline)
          assert_not link.available?(time: deadline + 0.000001)
          assert_includes ShareLink.active(deadline - 0.000001), link
          assert_not_includes ShareLink.active(deadline), link
        end
      end
    end
  end

  test "active excludes revoked links and the exact saved expiration boundary" do
    travel_to Time.current.change(usec: 123456), with_usec: true do
      finite = create_link(expiration: "one_day")
      never = create_legacy_link(expiration: "never")
      revoked = create_legacy_link(expiration: "never")
      ShareLink.revoke_all!(ShareLink.where(id: revoked.id))
      deadline = finite.expires_at

      assert_equal [ finite.id, never.id ].sort, ShareLink.active(deadline - 0.000001).pluck(:id).sort
      assert_equal [ never.id ], ShareLink.active(deadline).pluck(:id)
      assert_equal [ never.id ], ShareLink.active(deadline + 0.000001).pluck(:id)
    end
  end

  test "permanently shortens existing lifetimes without reviving links on policy relaxation" do
    old = travel_to(8.days.ago) { create_legacy_link(expiration: "never") }
    ongoing = travel_to(2.days.ago) { create_legacy_link(expiration: "thirty_days") }
    travel_to Time.current.change(usec: 0) do
      short = create_link(expiration: "one_day")
      short_deadline = short.expires_at
      revoked = create_legacy_link(expiration: "never")
      ShareLink.revoke_all!(ShareLink.where(id: revoked.id))
      tombstone = revoked.reload.revoked_at

      with_share_link_maximum_lifetime(7.days) do
        2.times { ShareLink.enforce_maximum_lifetime! }
        assert_equal old.created_at + 7.days, old.reload.expires_at
        assert_equal ongoing.created_at + 7.days, ongoing.reload.expires_at
        assert_equal short_deadline, short.reload.expires_at
        assert_equal tombstone, revoked.reload.revoked_at
        assert_not old.available?
        assert ongoing.available?
      end
      [ 30.days, nil ].each do |maximum|
        with_share_link_maximum_lifetime(maximum) do
          ShareLink.enforce_maximum_lifetime! if maximum
          assert_equal old.created_at + 7.days, old.reload.expires_at
          assert_equal ongoing.created_at + 7.days, ongoing.reload.expires_at
          assert_not old.available?
          assert_not revoked.reload.available?
        end
      end
    end
  end

  test "shortening requires a maximum instead of silently doing nothing" do
    link = create_legacy_link(expiration: "never")
    with_share_link_maximum_lifetime(nil) do
      error = assert_raises(ArgumentError) { ShareLink.enforce_maximum_lifetime! }
      assert_includes error.message, "maximum share-link lifetime"
      assert_nil link.reload.expires_at
    end
  end

  test "never visited legacy links cannot revive after completed activation and relaxation" do
    time = Time.current.change(usec: 123456)
    links = travel_to(time - 8.days, with_usec: true) do
      %w[never thirty_days].map { |expiration| create_legacy_link(expiration:) }
    end
    travel_to time, with_usec: true do
      with_share_link_maximum_lifetime(7.days) do
        ShareLink.enforce_maximum_lifetime!
      end
      [ 30.days, nil ].each do |maximum|
        with_share_link_maximum_lifetime(maximum) do
          links.each do |link|
            assert_equal link.created_at + 7.days, link.reload.expires_at
            assert_not link.available?
            assert_nil ShareLink.find_available(link.public_id)
          end
        end
      end
    end
  end

  test "shortening preserves already compliant deadlines and update timestamps" do
    links = %w[one_day seven_days].map { |expiration| create_link(expiration:) }
    original = links.map { |link| link.attributes.slice("expires_at", "updated_at") }
    travel 1.minute do
      ShareLink.enforce_maximum_lifetime!
      assert_equal original, links.map { |link| link.reload.attributes.slice("expires_at", "updated_at") }
    end
  end

  test "creator revocation remains available for legacy links before an explicit backfill" do
    legacy = %w[never thirty_days].map { |expiration| create_legacy_link(expiration:) }
    legacy.each { |link| SharePreviewGrant.issue!(share_link: link) }
    with_share_link_maximum_lifetime(7.days) do
      ShareLinkCreatorRevocation.confirm_loss!(repository: @repository, user: @creator)
      legacy.each do |link|
        assert link.reload.revoked_at
        assert_not link.available?
      end
      assert_empty SharePreviewGrant.all
    end
  end

  test "cleans capped links only at or after their creation time deadline" do
    time = Time.current.change(usec: 0)
    expired = travel_to(time - 7.days) { create_legacy_link(expiration: "never") }
    active = travel_to(time - 6.days) { create_legacy_link(expiration: "thirty_days") }
    travel_to time do
      with_share_link_maximum_lifetime(7.days) do
        assert_equal 1, ShareLink.clear_expired!
        assert_not ShareLink.exists?(expired.id)
        assert ShareLink.exists?(active.id)
      end
    end
  end

  test "rejects an unfinished Build and a Build from another Prototype" do
    second = prototypes.create(repository: @repository, branch_name: "prototype/other")
    queued = builds.create \
      prototype: @prototype,
      number: 2,
      commit_sha: "b" * 40
    other = builds.create_successful(prototype: second, commit_sha: "c" * 40)

    queued_link = ShareLink.new \
      prototype: @prototype,
      build: queued,
      created_by: @creator,
      label: "Queued"
    other_link = ShareLink.new \
      prototype: @prototype,
      build: other,
      created_by: @creator,
      label: "Other"

    assert_not queued_link.valid?
    assert_includes queued_link.errors[:build], "must be successful"
    assert_not other_link.valid?
    assert_includes other_link.errors[:build], "must belong to this prototype"
  end

  test "hides expired links and removed repositories" do
    link = ShareLink.create_public! \
      prototype: @prototype,
      build: @build,
      created_by: @creator,
      label: "Short review",
      expiration: "one_day"

    travel 2.days

    assert_not link.available?
    assert_not_includes ShareLink.active, link

    link.update_column(:expires_at, nil)
    @repository.update! \
      installation_state: "removed",
      removed_at: Time.current
    assert_not link.reload.available?
  end

  test "clears expired links without removing active links" do
    active = ShareLink.create_public! \
      prototype: @prototype,
      build: @build,
      created_by: @creator,
      label: "Active",
      expiration: "seven_days"
    expired = travel_to(2.days.ago) do
      ShareLink.create_public! \
        prototype: @prototype,
        build: @build,
        created_by: users.mona,
        label: "Expired",
        expiration: "one_day"
    end

    assert_equal 1, ShareLink.clear_expired!
    assert ShareLink.exists?(active.id)
    assert_not ShareLink.exists?(expired.id)
  end

  test "keeps its public and Build identity unchanged" do
    link = ShareLink.create_public! \
      prototype: @prototype,
      build: @build,
      created_by: @creator,
      label: "Design review",
      expiration: "seven_days"

    other_build = builds.create \
      prototype: @prototype,
      number: 2,
      commit_sha: "b" * 40

    assert_not link.update(public_id: SecureRandom.uuid, build: other_build, created_at: 1.day.from_now)
    assert_includes link.errors[:public_id], "cannot change"
    assert_includes link.errors[:build_id], "cannot change"
    assert_includes link.errors[:created_at], "cannot change"
  end

  test "enforces Prototype and Build identity in the database" do
    second = prototypes.create(repository: @repository, branch_name: "prototype/other")
    build = builds.create_successful(prototype: second)
    link = ShareLink.new \
      prototype: @prototype,
      build:,
      created_by: @creator,
      label: "Wrong branch",
      expires_at: 7.days.from_now
    link.valid?
    attributes = link.attributes.except("id")

    assert_raises(ActiveRecord::StatementInvalid) do
      ShareLink.insert_all!([ attributes ])
    end
  end

  test "rejects invalid expiration choices and labels over the byte limit" do
    assert_raises(ShareLink::InvalidExpiration) do
      ShareLink.create_public! \
        prototype: @prototype,
        build: @build,
        created_by: @creator,
        label: "Review",
        expiration: "later"
    end

    link = ShareLink.new \
      prototype: @prototype,
      build: @build,
      created_by: @creator,
      label: "é" * ((ShareLink::LABEL_MAXIMUM_BYTES / 2) + 1),
      expires_at: 7.days.from_now

    assert_not link.valid?
    assert_includes link.errors[:label], "must contain at most 100 bytes"
  end

  private

  def create_legacy_link(expiration:)
    with_share_link_maximum_lifetime(nil) { create_link(expiration:) }
  end

  def create_link(expiration: nil)
    ShareLink.create_public! \
      prototype: @prototype, build: @build, created_by: @creator, label: "Review", expiration:
  end
end
