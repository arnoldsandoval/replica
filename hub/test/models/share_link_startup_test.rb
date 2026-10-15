require "test_helper"
require "rake"

class ShareLinkStartupTest < ActiveSupport::TestCase
  setup do
    @original_setting = ENV["REPLICA_SHARE_LINK_MAX_DAYS"]
    @original_dummy_secret = ENV["SECRET_KEY_BASE_DUMMY"]
    @original_maximum = Rails.configuration.x.share_link_maximum_lifetime
    SharingSetting.create!(id: 1, public_sharing_enabled: true)
    seed "repositories/github_prototype"
  end

  teardown do
    ENV["REPLICA_SHARE_LINK_MAX_DAYS"] = @original_setting
    ENV["SECRET_KEY_BASE_DUMMY"] = @original_dummy_secret
    Rails.configuration.x.share_link_maximum_lifetime = @original_maximum
  end

  test "startup defaults to seven days and permanently expires legacy links" do
    old = travel_to(8.days.ago) { create_link }
    old.update_column(:expires_at, nil)
    ongoing = travel_to(2.days.ago) { create_link }
    ongoing.update_column(:expires_at, ongoing.created_at + 30.days)
    expired = travel_to(40.days.ago) { create_link }
    expired.update_column(:expires_at, expired.created_at + 30.days)
    short = create_link(expiration: "one_day")
    earlier = short.expires_at
    revoked = create_link
    revoked.update_columns(expires_at: nil, revoked_at: Time.current)
    tombstone = revoked.revoked_at

    assert_no_difference("ShareLink.count") { restart_with(nil) }

    assert_equal 7.days, Rails.configuration.x.share_link_maximum_lifetime
    assert_equal old.created_at + 7.days, old.reload.expires_at
    assert_not old.available?
    assert_equal ongoing.created_at + 7.days, ongoing.reload.expires_at
    assert ongoing.available?
    assert_equal expired.created_at + 7.days, expired.reload.expires_at
    assert_not expired.available?
    assert_equal earlier, short.reload.expires_at
    assert_equal tombstone, revoked.reload.revoked_at
    assert_equal revoked.created_at + 7.days, revoked.expires_at
  end

  test "repeated startup does not rewrite compliant deadlines or timestamps" do
    link = create_link
    link.update_column(:expires_at, nil)
    restart_with("7")
    original = link.reload.attributes.slice("created_at", "expires_at", "updated_at")

    travel 1.minute do
      restart_with("7")
      assert_equal original, link.reload.attributes.slice("created_at", "expires_at", "updated_at")
    end
  end

  test "a shorter maximum uses original creation time and cannot revive on relaxation" do
    restart_with("30")
    link = travel_to(2.days.ago) { create_link(expiration: "thirty_days") }

    restart_with("1")
    deadline = link.created_at + 1.day
    assert_equal deadline, link.reload.expires_at
    assert_not link.available?
    restart_with("30")
    assert_equal deadline, link.reload.expires_at
    assert_not link.available?
    assert_equal 30.days, Rails.configuration.x.share_link_maximum_lifetime
    new_link = create_link(expiration: "thirty_days")
    assert_equal new_link.created_at + 30.days, new_link.expires_at
  end

  test "removing a longer maximum restores seven days and shortens existing links" do
    restart_with("30")
    link = travel_to(6.days.ago) { create_link(expiration: "thirty_days") }

    restart_with(nil)

    assert_equal 7.days, Rails.configuration.x.share_link_maximum_lifetime
    assert_equal link.created_at + 7.days, link.reload.expires_at
    assert link.available?
    assert_equal %w[one_day seven_days], ShareLink.expiration_options.keys
  end

  test "removing a shorter maximum allows new seven day links without extending old links" do
    restart_with("1")
    old = create_link
    deadline = old.expires_at

    restart_with(nil)

    assert_equal deadline, old.reload.expires_at
    new_link = create_link
    assert_equal new_link.created_at + 7.days, new_link.expires_at
  end

  test "failed shortening rolls back all deadline changes and prevents startup" do
    first = create_link
    second = create_link
    [ first, second ].each { |link| link.update_column(:expires_at, nil) }
    failure = -> { throw :abort if id == second.id }
    ShareLink.set_callback(:update, :before, failure)

    assert_raises(ActiveRecord::RecordNotSaved) { restart_with("7") }
    assert_nil first.reload.expires_at
    assert_nil second.reload.expires_at
  ensure
    ShareLink.skip_callback(:update, :before, failure) if failure
  end

  test "invalid settings still prevent startup without changing deadlines" do
    link = create_link
    original = link.expires_at

    assert_raises(ArgumentError) { restart_with("") }
    assert_equal original, link.reload.expires_at
  end

  test "image builds and database preparation do not shorten deadlines" do
    link = create_link
    link.update_column(:expires_at, nil)
    ENV["SECRET_KEY_BASE_DUMMY"] = "1"
    restart_with("7")
    assert_nil link.reload.expires_at
    ENV["SECRET_KEY_BASE_DUMMY"] = nil
    application = Rake.application
    original_tasks = application.method(:top_level_tasks)
    application.define_singleton_method(:top_level_tasks) { [ "db:prepare" ] }
    restart_with("7")
    assert_nil link.reload.expires_at
  ensure
    application.define_singleton_method(:top_level_tasks, original_tasks) if original_tasks
  end

  private

  def restart_with(setting)
    ENV["REPLICA_SHARE_LINK_MAX_DAYS"] = setting
    load Rails.root.join("config/initializers/deployment_configuration.rb")
  end

  def create_link(expiration: nil)
    ShareLink.create_public! \
      prototype: prototypes.welcome,
      build: builds.welcome,
      created_by: users.octocat,
      label: "Startup verification",
      expiration:
  end
end
