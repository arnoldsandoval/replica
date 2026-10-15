require "test_helper"

class SharePreviewGrantTest < ActiveSupport::TestCase
  setup do
    SharingSetting.create!(id: 1, public_sharing_enabled: true)
    github_app_configurations.create_installed
  end

  test "redeems a grant once for its shared Build" do
    link = share_link
    token = SharePreviewGrant.issue!(share_link: link)

    grant = SharePreviewGrant.find_valid(token, build_id: link.build_id)

    assert_equal link, grant.share_link
    assert SharePreviewGrant.consume(grant)
    assert_nil SharePreviewGrant.find_valid(token, build_id: link.build_id)
  end

  test "keeps a grant when a different Build host presents it" do
    link = share_link
    token = SharePreviewGrant.issue!(share_link: link)

    assert_nil SharePreviewGrant.find_valid(token, build_id: link.build_id + 1)
    assert SharePreviewGrant.find_valid(token, build_id: link.build_id)
  end

  test "rejects expired grants and unavailable share links" do
    link = share_link
    expired = SharePreviewGrant.create! \
      share_link: link,
      token_digest: Digest::SHA256.hexdigest("expired"),
      expires_at: 1.minute.ago

    assert_nil SharePreviewGrant.find_valid("expired", build_id: link.build_id)

    token = SharePreviewGrant.issue!(share_link: link)
    link.destroy!

    assert_not SharePreviewGrant.exists?(expired.id)
    assert_nil SharePreviewGrant.find_valid(token, build_id: link.build_id)
  end

  private

  def share_link
    build = builds.create
    time = Time.current
    build.update! \
      state: "successful",
      started_at: time,
      finished_at: time,
      workflow_completed_at: time,
      github_workflow_run_id: build.id + 10_000,
      github_workflow_run_attempt: 1,
      workflow_url: "https://github.com/github/prototype/actions/runs/#{build.id + 10_000}",
      github_artifact_id: build.id + 20_000,
      artifact_prefix: "builds/#{build.id}",
      artifact_bytes: 100
    ShareLink.create_public! \
      prototype: build.prototype,
      build:,
      created_by: users.create,
      label: "Design review",
      expiration: "seven_days"
  end
end
