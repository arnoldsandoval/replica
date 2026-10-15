require "test_helper"

class AnalyticsTest < ActiveSupport::TestCase
  setup do
    @repository = repositories.create
    @prototype = prototypes.create(repository: @repository)
    @user = users.create
  end

  test "records registration once without a destination or source content" do
    assert_no_difference("Analytics::Event.count") do
      prototypes.create(repository: @repository, branch_name: "prototype/discovered")
    end
    2.times { @prototype.register!(name: "Private title", description: "Private content", author: @user) }

    event = Analytics::Event.sole
    assert_equal "prototype_registered", event.name
    assert_equal({ "repository_id" => @repository.id, "prototype_id" => @prototype.id }, event.properties)
    assert_equal @prototype.registered_at, event.occurred_at
    assert_match(/\A[0-9a-f-]{36}\z/, event.uuid)
    assert_equal Analytics.actor_id(github_id: @user.github_id), event.actor_id
    assert_not_includes event.to_json, "Private"
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(name: "build_published") }
  end

  test "rolls back the event with registration" do
    assert_no_difference("Analytics::Event.count") do
      Prototype.transaction do
        @prototype.register!(name: "Rolled back")
        raise ActiveRecord::Rollback
      end
    end
    assert_nil @prototype.reload.registered_at
  end

  test "automatic registration preserves the start page and records the author once" do
    @prototype.update!(name: "Saved title", start_page: "/settings")
    build = builds.create_successful(prototype: @prototype)

    2.times { assert @prototype.register_automatically!(commit_sha: build.commit_sha, author: @user) }

    assert_equal "Saved title", @prototype.reload.name
    assert_equal "/settings", @prototype.start_page
    assert_equal @user, @prototype.author
    event = Analytics::Event.find_by!(name: "prototype_registered")
    assert_equal Analytics.actor_id(user: @user), event.actor_id
    assert_equal 1, Analytics::Event.where(name: "prototype_registered").count
  end

  test "uses the same opaque identity for a commit author and reviewer in different repositories" do
    other = repositories.create(github_id: 2002, name_with_owner: "github/other")
    prototype = prototypes.create(repository: other)
    @prototype.register!(name: "First", author: @user)
    prototype.register!(name: "Other", author: @user)
    assert_equal 1, Analytics::Event.distinct.count(:actor_id)
    assert_equal Analytics.actor_id(user: @user), Analytics.actor_id(github_id: 1001)
    assert_not_equal "1001", Analytics.actor_id(user: @user)
    assert_nil Analytics.actor_id
    assert_equal [ @repository.id ], @repository.analytics_events.distinct.pluck(:repository_id)
  end

  test "classifies only the first successful publication even after event expiration" do
    first = builds.create_successful \
      prototype: @prototype, commit_author_github_id: 1001,
      commit_author_login: "octocat", commit_author_name: "Private name"
    first.touch
    assert_equal [ "prototype_first_published" ], Analytics::Event.pluck(:name)
    assert_equal first.finished_at, @prototype.reload.first_published_at
    assert_equal Analytics.actor_id(user: @user), Analytics::Event.sole.actor_id

    travel 91.days do
      Analytics::Event.clear_expired!
      assert_empty Analytics::Event.all
      builds.create_successful(prototype: @prototype, number: 2, commit_sha: "b" * 40)
      assert_equal "build_published", Analytics::Event.sole.name
      assert_equal first.finished_at, @prototype.reload.first_published_at
    end
  end

  test "replaying a publication keeps the original event and UUID" do
    build = builds.create_successful(prototype: @prototype)
    event = Analytics::Event.sole

    @prototype.record_publication!(build)

    assert_equal [ event.id ], Analytics::Event.pluck(:id)
    assert_equal event.uuid, Analytics::Event.sole.uuid
    assert_equal "prototype_first_published", Analytics::Event.sole.name
    assert_not @prototype.reload.update(first_published_at: 1.day.ago)
  end

  test "a publication rolls back when its event cannot be recorded" do
    @prototype.define_singleton_method(:record_publication!) { |_build| raise "analytics unavailable" }
    assert_raises(RuntimeError) { builds.create_successful(prototype: @prototype) }

    assert_equal "queued", Build.sole.state
    assert_nil @prototype.reload.first_published_at
    assert_empty Analytics::Event.all
  end

  test "backfills prior successful builds without inventing events" do
    require Rails.root.join("db/migrate/20260928195500_create_analytics_events")

    first = builds.create_successful(prototype: @prototype, at: 2.days.ago)
    builds.create_successful(prototype: @prototype, number: 2, commit_sha: "b" * 40, at: 1.day.ago)
    @prototype.update_columns(first_published_at: nil)
    Analytics::Event.delete_all

    CreateAnalyticsEvents.new.backfill_first_publications

    assert_equal first.finished_at, @prototype.reload.first_published_at
    assert_empty Analytics::Event.all
    builds.create_successful(prototype: @prototype, number: 3, commit_sha: "c" * 40)
    assert_equal [ "build_published" ], Analytics::Event.pluck(:name)
  end

  test "records roots replies and only real resolution transitions" do
    build = builds.create_successful(prototype: @prototype)
    comment = ReviewComment.create! \
      prototype: @prototype, build:, user: @user, body: "Private comment",
      anchor: {
        schemaVersion: 1, kind: "element", route: { pathname: "/", search: "", hash: "" },
        selector: "#save", accessibleName: "Save", tagName: "button", selectedText: "",
        rect: { x: 20, y: 30, width: 100, height: 32 },
        viewport: { width: 1280, height: 720, scrollX: 0, scrollY: 0 },
        elementOffset: { x: 0.5, y: 0.5 }
      }
    reply = comment.thread.create_reply!(user: @user, body: "Private reply")
    2.times { comment.thread.resolve_by!(@user) }
    2.times { comment.thread.reopen_by!(@user) }
    comment.thread.resolve_by!(@user)
    comment.thread.edit_body!("Private edit", actor: @user)

    assert_equal 2, Analytics::Event.where(name: "review_thread_resolved").count
    assert_equal 1, Analytics::Event.where(name: "review_thread_reopened").count
    event = Analytics::Event.find_by!(name: "review_reply_added")
    assert_equal reply.id, event.properties["comment_id"]
    assert_equal comment.id, event.properties["thread_id"]
    assert_equal build.id, event.properties["build_id"]
    assert_not_includes Analytics::Event.all.to_json, "Private"
    assert_equal 6, Analytics::Event.count
    assert_equal 6, Analytics::Event.distinct.count(:source_key)
  end

  test "rejects non-allowlisted events and properties" do
    assert_raises(ActiveRecord::RecordInvalid) do
      Analytics::Event.record! \
        repository: @repository, name: "other", source_key: "unknown/1",
        properties: { prototype_id: @prototype.id }
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      Analytics::Event.record! \
        repository: @repository, name: "prototype_registered", source_key: "unknown/2",
        properties: { prototype_id: @prototype.id, body: "Private comment" }
    end
    assert_empty Analytics::Event.all
  end

  test "clears only events older than 90 days" do
    travel_to(91.days.ago) { @prototype.register!(name: "Old") }
    recent = prototypes.create(repository: @repository, branch_name: "prototype/recent")
    recent.register!(name: "Recent")

    Analytics::Event.clear_expired!

    assert_equal [ "prototype/#{recent.id}/registered" ], Analytics::Event.pluck(:source_key)
    assert_equal 1, Analytics::Event.count
  end
end
