require "test_helper"
require "timeout"
require_relative "../../app/controllers/concerns/artifact_respondable"
require_relative "../support/share_link_lifetime_helpers"

# Exercises committed state through independent SQLite connections.
class PublicSharingConcurrencyTest < ActiveSupport::TestCase
  include ShareLinkLifetimeHelpers
  self.use_transactional_tests = false

  setup do
    @existing_audit_ids = SecurityAuditEvent.ids
    @configuration = github_app_configurations.create_installed
    @actor = users.create(github_id: 9101, login: "sharing-admin", hub_admin: true)
    @session = @actor.sessions.create!(fresh_authorized_at: Time.current)
    @repository = repositories.create
    @prototype = prototypes.create(repository: @repository)
    @build = builds.create_successful(prototype: @prototype)
    SharingSetting.create!(id: 1, public_sharing_enabled: true)
  end

  teardown do
    SecurityAuditEvent.where.not(id: @existing_audit_ids).delete_all
    Analytics::Event.where(repository: @repository).delete_all
    ShareLink.where(prototype: @prototype).delete_all
    Build.where(prototype: @prototype).delete_all
    @prototype.delete
    ShareLinkCreatorRevocation.where(repository: @repository).delete_all
    @repository.delete
    @session.delete
    @actor.delete
    @configuration.delete
    SharingSetting.delete_all
  end

  test "creation waiting behind disable sees disabled state instead of a stale allow" do
    revision = SharingSetting.revision
    entered = Queue.new
    release = Queue.new
    attempted = Queue.new
    disable = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SharingSetting.transaction do
          change("disable")
          entered << true
          release.pop
        end
      end
    end
    entered.pop
    creation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        attempted << true
        create_link(sharing_revision: revision)
        :created
      rescue SharingSetting::Disabled
        :disabled
      end
    end
    attempted.pop
    release << true
    disable.value
    assert_equal :disabled, creation.value
    assert_empty ShareLink.where(prototype: @prototype)
  ensure
    release << true if release
    [ disable, creation ].compact.each(&:join)
  end

  test "startup shortening waits for a writer and preserves its committed revocation" do
    link = create_link
    link.update_column(:expires_at, nil)
    entered = Queue.new
    release = Queue.new
    attempted = Queue.new
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ShareLink.transaction do
          ShareLink.find(link.id).update!(revoked_at: Time.current)
          entered << true
          release.pop
        end
      end
    end
    entered.pop
    startup = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        attempted << true
        ShareLink.enforce_maximum_lifetime!
      end
    end
    attempted.pop
    release << true
    writer.value
    startup.value

    assert link.reload.revoked_at
    assert_equal link.created_at + 7.days, link.expires_at
    assert_not link.available?
  ensure
    release << true if release
    [ writer, startup ].compact.each(&:join)
  end

  test "a settings change waiting behind role revocation rereads the saved role" do
    entered = Queue.new
    release = Queue.new
    role_change = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          User.find(@actor.id).update!(hub_admin: false)
          entered << true
          release.pop
        end
      end
    end
    entered.pop
    toggle = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        change("disable")
        :succeeded
      rescue SharingSetting::ChangeDenied => error
        error.reason
      end
    end
    release << true
    role_change.value
    assert_equal :not_authorized, toggle.value
    assert SharingSetting.enabled?
    assert_equal 0, SecurityAuditEvent.where(action: "sharing_settings.disable", outcome: "succeeded").count
  ensure
    release << true if release
    [ role_change, toggle ].compact.each(&:join)
  end

  test "a completed creation is revoked by the next serialized disable" do
    entered = Queue.new
    release = Queue.new
    creation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ShareLink.transaction do
          link = create_link
          SharePreviewGrant.issue!(share_link: link)
          entered << link.id
          release.pop
          link.id
        end
      end
    end
    id = entered.pop
    disable = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { change("disable") }
    end
    release << true
    creation.value
    disable.value
    assert ShareLink.find(id).revoked_at
    assert_empty SharePreviewGrant.where(share_link_id: id)
    change("enable")
    assert_not ShareLink.find(id).available?
  ensure
    release << true if release
    [ creation, disable ].compact.each(&:join)
  end

  test "an in flight body stops after another connection commits disable" do
    link = create_link
    delivered = Queue.new
    release = Queue.new
    sent = []
    body = Object.new
    body.define_singleton_method(:each) do |&block|
      block.call("first chunk")
      delivered << true
      release.pop
      block.call("second chunk")
    end
    stream = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        PublicShareResponseBody.new(body, link.id).each { |chunk| sent << chunk }
      end
    end
    delivered.pop
    change("disable")
    release << true
    stream.value
    assert_equal [ "first chunk" ], sent
    assert link.reload.revoked_at
  ensure
    release << true if release
    stream&.join
  end

  test "an in flight body stops at the mandatory creation time deadline" do
    travel_to Time.current.change(usec: 0) do
      link = create_link
      link.update_columns(created_at: 7.days.ago + 1.minute, expires_at: nil)
      sent = []
      advance = -> { travel_to link.created_at + 7.days }
      body = Object.new
      body.define_singleton_method(:each) do |&block|
        block.call("first chunk")
        advance.call
        block.call("second chunk")
      end
      with_share_link_maximum_lifetime(7.days) do
        PublicShareResponseBody.new(body, link.id).each { |chunk| sent << chunk }
      end
      assert_equal [ "first chunk" ], sent
    end
  end

  test "an earlier creator permission cannot win after confirmed loss commits" do
    proof = ShareLinkCreatorRevocation.proof_for(@repository, @actor)
    entered = Queue.new
    release = Queue.new
    loss = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ShareLinkCreatorRevocation.transaction do
          ShareLinkCreatorRevocation.confirm_loss!(repository: @repository, user: @actor)
          entered << true
          release.pop
        end
      end
    end
    entered.pop
    creation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        create_link(authorization_proof: proof)
        :created
      rescue ShareLinkCreatorRevocation::Changed
        :changed
      end
    end
    release << true
    loss.value
    assert_equal :changed, creation.value
    assert_empty ShareLink.where(prototype: @prototype)
  ensure
    release << true if release
    [ loss, creation ].compact.each(&:join)
  end

  test "cached policy before authorization cannot create after disable and reenable" do
    ActiveRecord::Base.cache do
      revision = SharingSetting.revision
      assert SharingSetting.enabled?
      on_other_connection do
        change("disable")
        change("enable")
      end

      assert_equal revision, SharingSetting.revision
      assert_raises(SharingSetting::Changed) do
        create_link(sharing_revision: revision)
      end
      assert_empty ShareLink.where(prototype: @prototype)
    end
  end

  test "cached creator proof cannot create after access is lost and regained" do
    ActiveRecord::Base.cache do
      proof = ShareLinkCreatorRevocation.proof_for(@repository, @actor)
      on_other_connection do
        ShareLinkCreatorRevocation.confirm_loss!(repository: @repository, user: @actor)
      end

      assert_equal proof, ShareLinkCreatorRevocation.proof_for(@repository, @actor)
      assert_raises(ShareLinkCreatorRevocation::Changed) do
        create_link(authorization_proof: proof)
      end
      assert_empty ShareLink.where(prototype: @prototype)
      fresh_proof = ShareLinkCreatorRevocation.uncached do
        ShareLinkCreatorRevocation.proof_for(@repository, @actor)
      end
      assert create_link(authorization_proof: fresh_proof).persisted?
    end
  end

  test "direct creation rejects a cached enabled policy after disable commits" do
    ActiveRecord::Base.cache do
      assert SharingSetting.enabled?
      on_other_connection { change("disable") }

      assert SharingSetting.enabled?
      assert_raises(SharingSetting::Disabled) do
        ShareLink.create! \
          prototype: @prototype, build: @build, created_by: @actor, label: "Direct",
          expires_at: 7.days.from_now
      end
      assert_empty ShareLink.where(prototype: @prototype)
    end
  end

  test "prepared public access rejects cached links after disable and reenable" do
    link = create_link
    ActiveRecord::Base.cache do
      cached_link = ShareLink.includes(build: { prototype: :repository }).find_by(id: link.id)
      assert cached_link.available?
      on_other_connection do
        change("disable")
        change("enable")
      end

      assert ShareLink.includes(build: { prototype: :repository }).find_by(id: link.id).available?
      ShareLink.with_available_access(link.id) { |available| assert_not available }
    end
  end

  test "prepared public access rereads cached repository availability" do
    link = create_link
    ActiveRecord::Base.cache do
      cached_link = ShareLink.includes(build: { prototype: :repository }).find_by(id: link.id)
      assert cached_link.available?
      on_other_connection do
        Repository.find(@repository.id).update! \
          installation_state: "removed",
          removed_at: Time.current
      end

      assert ShareLink.includes(build: { prototype: :repository }).find_by(id: link.id).available?
      ShareLink.with_available_access(link.id) { |available| assert_not available }
    end
  end

  test "cached stream checks stop after another connection confirms creator loss" do
    link = create_link
    body = [ "first chunk", "second chunk" ]
    sent = []
    ActiveRecord::Base.cache do
      cached_link = ShareLink.includes(build: { prototype: :repository }).find_by(id: link.id)
      assert cached_link.available?
      PublicShareResponseBody.new(body, link.id).each do |chunk|
        sent << chunk
        assert ShareLink.includes(build: { prototype: :repository }).find_by(id: link.id).available?
        on_other_connection do
          ShareLinkCreatorRevocation.confirm_loss!(repository: @repository, user: @actor)
        end
        assert ShareLink.includes(build: { prototype: :repository }).find_by(id: link.id).available?
      end
    end

    assert_equal [ "first chunk" ], sent
    assert link.reload.revoked_at
  end

  test "disable commits while an approved artifact chunk is still being sent" do
    link = create_link
    file = Tempfile.new([ "sharing-stalled-delivery-", ".bin" ], binmode: true)
    first_chunk = "a" * 64.kilobytes
    file.write(first_chunk + "next chunk")
    file.rewind
    entered = Queue.new
    release = Queue.new
    sent = []
    stream = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        PublicShareResponseBody.new(ArtifactResponseBody.new(file), link.id).each do |chunk|
          entered << chunk.bytesize
          release.pop
          sent << chunk
        end
      end
    end
    assert_equal 64.kilobytes, Timeout.timeout(5) { entered.pop }
    change("disable")
    assert link.reload.revoked_at
    assert stream.alive?
    release << true
    stream.value
    assert_equal [ first_chunk ], sent
    assert file.closed?
  ensure
    # Release both chunks if the regression lets the second one through.
    2.times { release << true } if release
    stream&.join
    file&.close!
  end

  private

  def on_other_connection(&block)
    ActiveRecord::Base.connection_pool.with_connection do |reader|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |writer|
          assert_not_same reader, writer
          block.call
        end
      end.value
    end
  end

  def change(operation)
    SharingSetting.change!(actor: @actor, browser_session: @session, operation:)
  end

  def create_link(**extra)
    ShareLink.create_public! \
      prototype: @prototype, build: @build, created_by: @actor, label: "Concurrent",
      **extra
  end
end
