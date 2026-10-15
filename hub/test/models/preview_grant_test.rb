require "test_helper"

class PreviewGrantTest < ActiveSupport::TestCase
  test "redeems a grant once for its Build" do
    browser_session = sessions.create
    build = builds.create
    token = PreviewGrant.issue!(build:, session: browser_session, return_path: "/settings")

    grant = PreviewGrant.find_valid(token, build_id: build.id)

    assert_equal build, grant.build
    assert_equal browser_session, grant.session
    assert_equal "/settings", grant.return_path
    assert PreviewGrant.consume(grant)
    assert_nil PreviewGrant.find_valid(token, build_id: build.id)
  end

  test "keeps a grant when a different Build host presents it" do
    browser_session = sessions.create
    build = builds.create
    other_build = builds.create(prototype: build.prototype, number: 2, commit_sha: "b" * 40)
    token = PreviewGrant.issue!(build:, session: browser_session, return_path: "/")

    assert_nil PreviewGrant.find_valid(token, build_id: other_build.id)
    assert PreviewGrant.find_valid(token, build_id: build.id)
  end

  test "rejects an expired grant" do
    grant = PreviewGrant.create! \
      build: builds.create,
      session: sessions.create,
      token_digest: Digest::SHA256.hexdigest("expired"),
      return_path: "/",
      expires_at: 1.minute.ago

    assert_nil PreviewGrant.find_valid("expired", build_id: grant.build_id)
  end

  test "a deleted Session cannot issue or consume a handoff through stale model instances" do
    browser_session = sessions.create
    build = builds.create
    token = PreviewGrant.issue!(build:, session: browser_session, return_path: "/")
    grant = PreviewGrant.find_valid(token, build_id: build.id)
    browser_session.destroy!
    assert_not PreviewGrant.consume(grant)
    assert_raises(ActiveRecord::RecordNotFound) do
      PreviewGrant.issue!(build:, session: browser_session, return_path: "/")
    end
    assert_empty PreviewGrant.all
  end

  test "rejects unsafe return paths" do
    browser_session = sessions.create
    build = builds.create

    [ "https://example.com", "//example.com", "/path\nheader", "/path\\file" ].each do |return_path|
      assert_raises(ArgumentError) do
        PreviewGrant.issue!(build:, session: browser_session, return_path:)
      end
    end
  end

  test "rejects control characters and whitespace before issuing a grant" do
    browser_session = sessions.create
    build = builds.create

    ((0..32).map(&:chr) + [ "\x7f", "\u00a0" ]).each do |character|
      assert_no_difference "PreviewGrant.count" do
        assert_raises(ArgumentError) do
          PreviewGrant.issue!(build:, session: browser_session, return_path: "/#{character}/example.com")
        end
      end
    end
    assert_equal "/hello%20world?q=a%20b#details",
      PreviewGrant.validate_return_path("/hello%20world?q=a%20b#details")
  end
end
