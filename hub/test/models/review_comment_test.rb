require "test_helper"

class ReviewCommentTest < ActiveSupport::TestCase
  test "stores one root comment with immutable thread identity" do
    build = builds.create_successful
    comment = ReviewComment.create! \
      prototype: build.prototype,
      build:,
      user: users.create,
      body: "Please align this control.",
      anchor: valid_anchor

    assert_equal "button", comment.anchor.fetch("tagName")
    assert_equal ReviewComment::ANCHOR_SCHEMA_VERSION, comment.anchor.fetch("schemaVersion")
    assert comment.root_comment?
    assert_nil comment.root
    assert_equal 1, comment.activity_version
    assert_equal 1, comment.thread_reads.find_by!(user: comment.user).last_seen_activity_version

    comment.thread.edit_body!("Changed", actor: comment.user)
    assert_equal "Changed", comment.body
    assert_not_nil comment.edited_at
    assert_equal 2, comment.activity_version

    comment.reload
    comment.anchor["selector"] = "#other"
    assert_not comment.save
    assert_includes comment.errors[:anchor], "cannot change"
  end

  test "stores flat replies without copying the root anchor or Build" do
    build = builds.create_successful
    author = users.create
    root = ReviewComment.create! \
      prototype: build.prototype,
      build:,
      user: author,
      body: "Please align this control.",
      anchor: valid_anchor

    reply = root.thread.create_reply! \
      user: users.create(github_id: 1_002, login: "mona"),
      body: "I updated the spacing."

    assert reply.reply?
    assert_equal root, reply.root
    assert_equal root.prototype, reply.prototype
    assert_nil reply.build
    assert_nil reply.anchor
    assert_equal [ reply ], root.replies
    assert_equal 2, root.reload.activity_version
    assert_equal 2, root.thread_reads.find_by!(user: reply.user).last_seen_activity_version
    assert_raises(ActiveRecord::RecordInvalid) do
      reply.thread.create_reply!(user: author, body: "Nested reply")
    end
  end

  test "rejects replies that cross Prototype boundaries or point to another reply" do
    first = prototypes.create
    second = prototypes.create(repository: first.repository, branch_name: "prototype/other")
    root_build = builds.create_successful(prototype: first)
    root = ReviewComment.create! \
      prototype: first,
      build: root_build,
      user: users.create,
      body: "Root",
      anchor: valid_anchor
    reply = root.thread.create_reply! \
      user: users.create(github_id: 1_002, login: "mona"),
      body: "Reply"

    cross_prototype = ReviewComment.new \
      prototype: second,
      root:,
      user: users.create(github_id: 1_003, login: "hubot"),
      body: "Wrong Prototype"
    nested = ReviewComment.new \
      prototype: first,
      root: reply,
      user: users.create(github_id: 1_004, login: "primer"),
      body: "Nested"

    assert_not cross_prototype.valid?
    assert_includes cross_prototype.errors[:root], "must belong to this prototype"
    assert_not nested.valid?
    assert_includes nested.errors[:root], "must be a root comment"
  end

  test "edits and deletes bodies without changing thread identity" do
    build = builds.create_successful
    author = users.create
    root = ReviewComment.create! \
      prototype: build.prototype,
      build:,
      user: author,
      body: "Original",
      anchor: valid_anchor

    assert root.editable_by?(author)
    assert_not root.editable_by?(users.create(github_id: 1_002, login: "mona"))

    root.thread.edit_body!("Updated", actor: author)
    assert_equal "Updated", root.body
    assert_not_nil root.edited_at
    assert_equal 2, root.activity_version

    root.thread.delete_body!(actor: author)
    assert_nil root.body
    assert_nil root.edited_at
    assert_not_nil root.deleted_at
    assert_equal 3, root.activity_version
    assert_equal 3, root.thread_reads.find_by!(user: author).last_seen_activity_version
    assert_not root.editable_by?(author)
    assert_raises(ActiveRecord::RecordInvalid) do
      root.thread.edit_body!("Restored", actor: author)
    end
    assert_not root.update(deleted_at: nil, body: "Restored")
    assert_includes root.errors[:deleted_at], "cannot change"
  end

  test "resolves and reopens a root while keeping replies unresolved" do
    build = builds.create_successful
    root = ReviewComment.create! \
      prototype: build.prototype,
      build:,
      user: users.create,
      body: "Root",
      anchor: valid_anchor
    reviewer = users.create(github_id: 1_002, login: "mona")
    reply = root.thread.create_reply!(user: reviewer, body: "Reply")

    root.thread.resolve_by!(reviewer)
    assert_not_nil root.resolved_at
    assert_equal reviewer, root.resolved_by
    assert_equal 3, root.activity_version
    assert_raises(ActiveRecord::RecordInvalid) do
      root.thread.create_reply!(user: reviewer, body: "Reply while resolved")
    end

    reply.resolved_at = Time.current
    reply.resolved_by = reviewer
    assert_not reply.valid?
    assert_includes reply.errors[:resolved_at], "must belong to the root comment"

    root.thread.reopen_by!(reviewer)
    assert_nil root.resolved_at
    assert_nil root.resolved_by
    assert_equal 4, root.activity_version
    assert root.thread.create_reply!(user: reviewer, body: "Reply after reopening")
    assert_equal 5, root.reload.activity_version
  end

  test "keeps replies when the root body is deleted" do
    build = builds.create_successful
    root = ReviewComment.create! \
      prototype: build.prototype,
      build:,
      user: users.create,
      body: "Root",
      anchor: valid_anchor
    reply = root.thread.create_reply! \
      user: users.create(github_id: 1_002, login: "mona"),
      body: "Reply"

    root.thread.delete_body!(actor: root.user)

    assert_equal [ reply ], root.replies.reload
    assert_nil root.body
    assert_not_nil root.anchor
    assert_not_nil root.build
  end

  test "stores one immutable area comment with sampled element context" do
    build = builds.create_successful
    comment = ReviewComment.create! \
      prototype: build.prototype,
      build:,
      user: users.create,
      body: "Keep this region aligned.",
      anchor: valid_area_anchor

    assert_equal "area", comment.anchor.fetch("kind")
    assert_equal ReviewComment::ANCHOR_SCHEMA_VERSION, comment.anchor.fetch("schemaVersion")
    assert_equal 2, comment.anchor.fetch("path").length
    assert_equal "button", comment.anchor.fetch("elements").first.fetch("tagName")
  end

  test "requires the originating Build to be successful and in the Prototype" do
    first = prototypes.create
    second = prototypes.create(repository: first.repository, branch_name: "prototype/other")
    queued = builds.create(prototype: first)
    other = builds.create_successful(prototype: second, commit_sha: "b" * 40)

    queued_comment = ReviewComment.new \
      prototype: first,
      build: queued,
      user: users.create,
      body: "Queued",
      anchor: valid_anchor
    other_comment = ReviewComment.new \
      prototype: first,
      build: other,
      user: users.create(github_id: 1_002, login: "mona"),
      body: "Other",
      anchor: valid_anchor

    assert_not queued_comment.valid?
    assert_includes queued_comment.errors[:build], "must be successful"
    assert_not other_comment.valid?
    assert_includes other_comment.errors[:build], "must belong to this prototype"
  end

  test "enforces Prototype and Build identity in the database" do
    first = prototypes.create
    second = prototypes.create(repository: first.repository, branch_name: "prototype/other")
    build = builds.create_successful(prototype: second)
    comment = ReviewComment.new \
      prototype: first,
      build:,
      user: users.create,
      body: "Wrong branch",
      anchor: valid_anchor
    comment.valid?
    attributes = comment.attributes.except("id")

    assert_raises(ActiveRecord::StatementInvalid) do
      ReviewComment.insert_all!([ attributes ])
    end
  end

  test "requires a nonblank body within the UTF-8 byte limit" do
    build = builds.create_successful
    blank = ReviewComment.new \
      prototype: build.prototype,
      build:,
      user: users.create,
      body: " \n",
      anchor: valid_anchor
    oversized = ReviewComment.new \
      prototype: build.prototype,
      build:,
      user: users.create(github_id: 1_002, login: "mona"),
      body: "é" * ((ReviewComment::BODY_MAXIMUM_BYTES / 2) + 1),
      anchor: valid_anchor

    assert_not blank.valid?
    assert_includes blank.errors[:body], "can't be blank"
    assert_not oversized.valid?
    assert_includes \
      oversized.errors[:body],
      "must be #{ReviewComment::BODY_MAXIMUM_BYTES} UTF-8 bytes or fewer"
  end

  test "rejects undocumented anchor fields and invalid route strings" do
    build = builds.create_successful
    anchor = valid_anchor.merge("extra" => true)
    anchor["route"] = anchor.fetch("route").merge("pathname" => "settings")
    comment = ReviewComment.new \
      prototype: build.prototype,
      build:,
      user: users.create,
      body: "Invalid anchor",
      anchor: anchor

    assert_not comment.valid?
    assert_includes comment.errors[:anchor], "contains unsupported fields: extra"
    assert_includes comment.errors[:anchor], "route.pathname must start with /"
  end

  test "rejects unsupported schema versions for either anchor kind" do
    build = builds.create_successful
    user = users.create

    [ valid_anchor, valid_area_anchor ].each do |anchor|
      comment = ReviewComment.new \
        prototype: build.prototype,
        build:,
        user:,
        body: "Unsupported schema",
        anchor: anchor.merge("schemaVersion" => 2)

      assert_not comment.valid?
      assert_includes comment.errors[:anchor], "schemaVersion must be 1"
    end
  end

  test "rejects nonfinite geometry and offsets outside the element" do
    build = builds.create_successful
    anchor = valid_anchor
    anchor["rect"] = anchor.fetch("rect").merge("x" => Float::NAN)
    anchor["viewport"] = anchor.fetch("viewport").merge("width" => 0)
    anchor["elementOffset"] = { "x" => 1.1, "y" => -0.1 }
    comment = ReviewComment.new \
      prototype: build.prototype,
      build:,
      user: users.create,
      body: "Invalid geometry",
      anchor: anchor

    assert_not comment.valid?
    assert_includes comment.errors[:anchor], "rect.x must be a finite number"
    assert_includes \
      comment.errors[:anchor],
      "viewport.width must be between 1 and #{ReviewComment::VIEWPORT_DIMENSION_MAXIMUM}"
    assert_includes comment.errors[:anchor], "elementOffset.x must be between 0 and 1"
    assert_includes comment.errors[:anchor], "elementOffset.y must be between 0 and 1"
  end

  test "rejects oversized, tiny, and malformed area anchors" do
    build = builds.create_successful
    anchor = valid_area_anchor
    anchor["path"] = Array.new(ReviewComment::AREA_PATH_MAXIMUM_POINTS + 1) do
      { "x" => 0.5, "y" => 0.5 }
    end
    anchor["rect"] = anchor.fetch("rect").merge("width" => 1, "height" => 1)
    anchor["elements"].first["textExcerpt"] =
      "x" * (ReviewComment::AREA_TEXT_EXCERPT_MAXIMUM_BYTES + 1)
    comment = ReviewComment.new \
      prototype: build.prototype,
      build:,
      user: users.create,
      body: "Invalid area",
      anchor: anchor

    assert_not comment.valid?
    assert_includes \
      comment.errors[:anchor],
      "path must contain between 2 and #{ReviewComment::AREA_PATH_MAXIMUM_POINTS} points"
    assert_includes \
      comment.errors[:anchor],
      "rect diagonal must be at least #{ReviewComment::AREA_MINIMUM_DIAGONAL} pixels"
    assert_includes \
      comment.errors[:anchor],
      "elements[0].textExcerpt must be #{ReviewComment::AREA_TEXT_EXCERPT_MAXIMUM_BYTES} " \
        "UTF-8 bytes or fewer"
  end

  test "limits sampled area elements and total anchor bytes" do
    build = builds.create_successful
    element = valid_area_anchor.fetch("elements").first
    too_many = valid_area_anchor
    too_many["elements"] = Array.new(ReviewComment::AREA_ELEMENTS_MAXIMUM + 1) do |index|
      element.merge("selector" => "#item-#{index}")
    end
    too_large = valid_area_anchor
    too_large["elements"] = Array.new(ReviewComment::AREA_ELEMENTS_MAXIMUM) do |index|
      element.merge("selector" => "##{"x" * 3_000}-#{index}")
    end

    too_many_comment = ReviewComment.new \
      prototype: build.prototype,
      build:,
      user: users.create,
      body: "Too many samples",
      anchor: too_many
    too_large_comment = ReviewComment.new \
      prototype: build.prototype,
      build:,
      user: users.create(github_id: 1_002, login: "mona"),
      body: "Too much context",
      anchor: too_large

    assert_not too_many_comment.valid?
    assert_includes \
      too_many_comment.errors[:anchor],
      "elements must contain at most #{ReviewComment::AREA_ELEMENTS_MAXIMUM} entries"
    assert_not too_large_comment.valid?
    assert_includes \
      too_large_comment.errors[:anchor],
      "must be #{ReviewComment::ANCHOR_MAXIMUM_BYTES} UTF-8 bytes or fewer"
  end

  test "enforces body and anchor shape in the database" do
    build = builds.create_successful
    comment = ReviewComment.new \
      prototype: build.prototype,
      build:,
      user: users.create,
      body: "Valid",
      anchor: valid_anchor
    comment.valid?
    attributes = comment.attributes.except("id")

    assert_raises(ActiveRecord::StatementInvalid) do
      ReviewComment.insert_all!([ attributes.merge("body" => " ") ])
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ReviewComment.insert_all!([ attributes.merge("anchor" => []) ])
    end
  end

  test "enforces root and reply field shapes in the database" do
    build = builds.create_successful
    root = ReviewComment.create! \
      prototype: build.prototype,
      build:,
      user: users.create,
      body: "Root",
      anchor: valid_anchor
    reply = ReviewComment.new \
      prototype: root.prototype,
      root:,
      user: users.create(github_id: 1_002, login: "mona"),
      body: "Reply"
    attributes = reply.attributes.except("id")
    other_prototype = prototypes.create \
      repository: root.prototype.repository,
      branch_name: "prototype/other"

    assert_raises(ActiveRecord::StatementInvalid) do
      ReviewComment.insert_all!([
        attributes.merge("build_id" => build.id, "anchor" => valid_anchor)
      ])
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ReviewComment.insert_all!([
        attributes.merge("prototype_id" => other_prototype.id)
      ])
    end
  end

  test "adds fixed reactions without changing thread activity" do
    build = builds.create_successful
    author = users.create
    reviewer = users.create(github_id: 1_002, login: "mona")
    root = ReviewComment.create! \
      prototype: build.prototype,
      build:,
      user: author,
      body: "Root",
      anchor: valid_anchor
    root.thread.create_reply!(user: author, body: "New activity")

    root.thread.add_reaction! \
      user: reviewer,
      content: "heart",
      activity_version: 1
    root.thread.add_reaction! \
      user: reviewer,
      content: "heart",
      activity_version: 2

    assert_equal 1, root.reactions.count
    assert_equal "heart", root.reactions.first.content
    assert_equal 2, root.reload.activity_version
    assert_equal 2, root.thread_reads.find_by!(user: reviewer).last_seen_activity_version

    assert_raises(ActiveRecord::RecordInvalid) do
      root.thread.add_reaction! \
        user: reviewer,
        content: "wave",
        activity_version: 2
    end

    root.thread.remove_reaction! \
      user: reviewer,
      content: "heart",
      activity_version: 2
    assert_empty root.reactions.reload
  end

  test "records only the activity version a reviewer has seen" do
    build = builds.create_successful
    author = users.create
    reviewer = users.create(github_id: 1_002, login: "mona")
    root = ReviewComment.create! \
      prototype: build.prototype,
      build:,
      user: author,
      body: "Root",
      anchor: valid_anchor
    root.thread.create_reply!(user: reviewer, body: "Reply")

    root.thread.record_read_by!(author, activity_version: 1)
    assert_equal 1, root.thread_reads.find_by!(user: author).last_seen_activity_version

    root.thread.record_read_by!(author, activity_version: 2)
    assert_equal 2, root.thread_reads.find_by!(user: author).last_seen_activity_version

    assert_raises(ActiveRecord::RecordInvalid) do
      root.thread.record_read_by!(author, activity_version: 3)
    end
  end

  private

  def valid_anchor
    {
      "schemaVersion" => 1,
      "kind" => "element",
      "route" => { "pathname" => "/", "search" => "", "hash" => "" },
      "selector" => "#save",
      "accessibleName" => "Save",
      "tagName" => "button",
      "selectedText" => "",
      "rect" => { "x" => 20, "y" => 30, "width" => 100, "height" => 32 },
      "viewport" => { "width" => 1_280, "height" => 720, "scrollX" => 0, "scrollY" => 0 },
      "elementOffset" => { "x" => 0.5, "y" => 0.5 }
    }
  end

  def valid_area_anchor
    {
      "schemaVersion" => 1,
      "kind" => "area",
      "route" => { "pathname" => "/", "search" => "", "hash" => "" },
      "path" => [ { "x" => 0, "y" => 0 }, { "x" => 1, "y" => 1 } ],
      "rect" => { "x" => 20, "y" => 30, "width" => 160, "height" => 80 },
      "viewport" => { "width" => 1_280, "height" => 720, "scrollX" => 0, "scrollY" => 0 },
      "elements" => [
        {
          "selector" => "#save",
          "accessibleName" => "Save",
          "tagName" => "button",
          "role" => "",
          "textExcerpt" => "Save changes",
          "rect" => { "x" => 40, "y" => 50, "width" => 100, "height" => 32 }
        }
      ]
    }
  end
end
