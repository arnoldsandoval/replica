require "test_helper"

class WebhookRecoveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    travel_to Time.current.change(usec: 0)
    @configuration = github_app_configurations.create_installed
    @checkpoint = WebhookRecoveryCheckpoint.create! \
      github_app_configuration_id: @configuration.id, github_app_id: @configuration.github_app_id,
      due_at: Time.current
    stub_app
  end

  teardown { travel_back }

  test "unknown transient failures become metadata-only resend work and succeed only on verified receipt" do
    api_page([ metadata(delivered_at: 2.days.ago.iso8601) ])
    @checkpoint.recover!
    entry = WebhookRedelivery.sole
    assert_equal "pending", entry.state
    assert_empty WebhookDelivery.all
    request = stub_request(:post, "https://api.github.com/app/hook/deliveries/1234/attempts")
      .with { assert_app_jwt(_1); true }.to_return(status: 202, body: "")
    travel 1.minute
    @checkpoint.reload.recover!
    assert_requested request, times: 1
    assert_equal "waiting", entry.reload.state
    assert_equal 1, entry.attempts
    assert_empty WebhookDelivery.all
    assert_empty entry.attributes.keys.grep(/body|payload|secret|token/).reject { _1 == "lease_token" }

    body = JSON.generate(
      installation: { id: 456 }, deleted: true,
      repository: { id: 2001, default_branch: "main" }, ref: "refs/heads/prototype/welcome"
    )
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @configuration.webhook_secret, body)}"
    GithubWebhook.process!(configuration: @configuration, body:, signature:, event: "push", delivery_id: "remote-guid")
    assert_equal "succeeded", entry.reload.state
    assert WebhookDelivery.sole.processed?
    api_page([ metadata(id: 5678, status_code: 503, redelivery: true) ])
    travel 1.minute
    @checkpoint.reload.recover!
    assert_requested request, times: 1
    assert_equal 1, WebhookRedelivery.count
  end

  test "unknown remote rate limits and transport failures request bounded normally verified redelivery" do
    statuses = [ 429, nil, 0, 500, 599 ]
    api_page(statuses.each_with_index.map do |status, index|
      metadata(guid: "missed-#{index}", id: index + 1, status_code: status)
    end)
    @checkpoint.recover!
    assert_equal statuses.size, WebhookRedelivery.count
    assert_empty WebhookDelivery.all
    statuses.each_index do |index|
      stub_request(:post, "https://api.github.com/app/hook/deliveries/#{index + 1}/attempts")
        .with { assert_app_jwt(_1); true }.to_return(status: 202, body: "")
    end
    travel 1.minute
    @checkpoint.reload.recover!
    statuses.each_index do |index|
      assert_requested :post, "https://api.github.com/app/hook/deliveries/#{index + 1}/attempts", times: 1
    end
    assert_equal [ "waiting" ], WebhookRedelivery.distinct.pluck(:state)
    assert_empty WebhookDelivery.all
  end

  test "unknown delivery metadata cannot extend the three-day recovery boundary" do
    first = 3.days.ago + 1.second
    api_page [
      metadata(guid: "within-window", delivered_at: first.iso8601),
      metadata(guid: "expired-window", delivered_at: 3.days.ago.iso8601)
    ]
    @checkpoint.recover!
    entry = WebhookRedelivery.sole
    assert_equal "within-window", entry.github_delivery_id
    assert_equal 1.second.from_now, entry.expires_at
    travel 1.second
    WebhookRedelivery.expire!
    assert_equal "window_expired", entry.reload.failure_code
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
  end

  test "unsupported authentication failures and successful GUIDs never create remote recovery work" do
    api_page [
      metadata(guid: "unsupported", event: "issues", action: "opened"),
      metadata(guid: "invalid-signature", status_code: 401),
      metadata(guid: "no-configuration", status_code: 401),
      metadata(guid: "success", status_code: 202),
      metadata(guid: "bad-request", status_code: 400)
    ]
    @checkpoint.recover!
    assert_empty WebhookRedelivery.all
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
  end

  test "late metadata uses the constant GUID and changes only the numeric attempt identity" do
    receipt = webhook_deliveries.create(github_delivery_id: "remote-guid")
    entry = WebhookRedelivery.record_throttle!(configuration: @configuration, delivery: receipt, installation_id: 456)
    api_page([])
    @checkpoint.recover!
    assert_nil entry.reload.github_attempt_id
    original_time = 2.hours.ago
    api_page([ metadata(id: 5678, redelivery: true, delivered_at: original_time.iso8601) ])
    stub_request(:post, "https://api.github.com/app/hook/deliveries/5678/attempts").to_return(status: 202, body: "")
    travel 1.minute
    @checkpoint.reload.recover!
    assert_equal 5678, entry.reload.github_attempt_id
    assert_equal "remote-guid", entry.github_delivery_id
    assert_equal original_time + 3.days, entry.expires_at
  end

  test "queue rejection failure and a vanished queued job leave a recoverable durable checkpoint" do
    original = @checkpoint.method(:recover_later!)
    @checkpoint.define_singleton_method(:recover_later!) { false }
    @checkpoint.enqueue
    assert_nil @checkpoint.reload.enqueue_claim_expires_at
    @checkpoint.define_singleton_method(:recover_later!) { raise ActiveJob::EnqueueError, "unavailable" }
    @checkpoint.enqueue
    assert_nil @checkpoint.reload.enqueue_claim_expires_at
    @checkpoint.define_singleton_method(:recover_later!, original)
    assert_enqueued_jobs(1) { WebhookRecoveryCheckpoint.recover_all! }
    assert_enqueued_jobs(0) { WebhookRecoveryCheckpoint.recover_all! }
    travel_to @checkpoint.reload.enqueue_claim_expires_at + 1.second
    assert_enqueued_jobs(1) { WebhookRecoveryCheckpoint.recover_all! }
  end

  test "a partial scan failure retains the last confirmed opaque cursor and resumes without duplicate work" do
    cursor = "opaque+cursor/one="
    api_page([ metadata ], cursor:)
    stub_request(:get, "https://api.github.com/app/hook/deliveries")
      .with(query: { per_page: "100", cursor: }).to_return(status: 503, body: "{}")
    @checkpoint.recover!
    assert_equal cursor, @checkpoint.reload.cursor
    assert_equal "github_unavailable", @checkpoint.failure_code
    assert_equal 1, @checkpoint.failures
    assert_equal 1, WebhookRedelivery.count
    api_page([], request_cursor: cursor)
    stub_request(:post, "https://api.github.com/app/hook/deliveries/1234/attempts").to_return(status: 202, body: "")
    travel_to @checkpoint.due_at
    @checkpoint.recover!
    assert_nil @checkpoint.reload.cursor
    assert_nil @checkpoint.failure_code
    assert_equal 1, WebhookRedelivery.count
    assert_not_nil @checkpoint.last_completed_at
  end

  test "API work is outside model transactions and each job bounds pages and resend pressure" do
    depth = WebhookRecoveryCheckpoint.connection.open_transactions
    stub_request(:get, "https://api.github.com/app/hook/deliveries")
      .with(query: hash_including("per_page" => "100")).to_return do |request|
        assert_equal depth, WebhookRecoveryCheckpoint.connection.open_transactions
        current = Rack::Utils.parse_query(URI(request.uri).query)["cursor"].to_i
        { status: 200, body: JSON.generate(100.times.map { |index| metadata(guid: "guid-#{current}-#{index}", id: current * 100 + index + 1) }),
          headers: { "Link" => "<https://api.github.com/app/hook/deliveries?per_page=100&cursor=#{current + 1}>; rel=\"next\"" } }
      end
    @checkpoint.recover!
    assert_equal 10, @checkpoint.reload.pages
    assert_equal "10", @checkpoint.cursor
    assert_equal 1_000, WebhookRedelivery.count
    stub_request(:post, %r{https://api\.github\.com/app/hook/deliveries/\d+/attempts}).to_return do
      assert_equal depth, WebhookRedelivery.connection.open_transactions
      { status: 202, body: "" }
    end
    travel 1.minute
    @checkpoint.recover!
    assert_requested :post, %r{/app/hook/deliveries/\d+/attempts}, times: 30
  end

  test "malformed foreign and repeated cursors do not cause credentialed outbound requests" do
    api_page([], raw_link: "malformed-pagination")
    @checkpoint.recover!
    assert_equal "invalid_response", @checkpoint.reload.failure_code
    assert_nil @checkpoint.last_completed_at
    [
      "https://attacker.example/app/hook/deliveries?per_page=100&cursor=bad",
      "https://api.github.com/user?per_page=100&cursor=bad",
      "https://api.github.com/app/hook/deliveries?per_page=100&cursor=bad&cursor=other"
    ].each do |link|
      api_page([], raw_link: "<#{link}>; rel=\"next\"")
      @checkpoint.update!(due_at: Time.current)
      @checkpoint.recover!
      assert_equal "invalid_response", @checkpoint.reload.failure_code
      assert_nil @checkpoint.cursor
    end
    assert_not_requested :get, %r{https://attacker\.example/}
    assert_not_requested :get, "https://api.github.com/user"
    api_page([], request_cursor: "repeated", cursor: "repeated")
    @checkpoint.update!(cursor: "repeated", due_at: Time.current, scan_started_at: Time.current)
    @checkpoint.recover!
    assert_equal "invalid_response", @checkpoint.reload.failure_code
  end

  test "an App mismatch removal replacement or stale installation cannot request a resend" do
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "remote-guid", event: "push", installation_id: 456,
      delivered_at: Time.current, attempt_id: 1234
    entry.update!(due_at: Time.current)
    stub_app(id: 999)
    @checkpoint.recover!
    assert_equal "invalid_response", @checkpoint.reload.failure_code
    assert_not_requested :get, %r{/app/hook/deliveries}
    @configuration.update!(installation_state: "removed")
    entry.redeliver!(configuration: @configuration)
    assert_equal "installation_changed", entry.reload.failure_code
    @configuration.destroy!
    replacement = github_app_configurations.create_installed(github_app_id: 987)
    @checkpoint.update!(due_at: Time.current)
    @checkpoint.recover!
    assert_equal "app_changed", @checkpoint.reload.failure_code
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
    assert_equal 987, replacement.github_app_id
  end

  test "resend failure backoff abandoned leases exhaustion and expiry remain explicit" do
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "remote-guid", event: "push", installation_id: 456,
      delivered_at: Time.current, attempt_id: 1234
    entry.update!(state: "requesting", attempts: 1, lease_token: "abandoned", due_at: Time.current)
    request = stub_request(:post, "https://api.github.com/app/hook/deliveries/1234/attempts")
      .to_return(status: 503, body: "{}")
    entry.redeliver!(configuration: @configuration)
    assert_equal "waiting", entry.reload.state
    assert_equal 2, entry.attempts
    assert_equal "github_unavailable", entry.failure_code
    assert_equal 2.minutes.from_now, entry.due_at
    entry.redeliver!(configuration: @configuration)
    assert_requested request, times: 1
    entry.update!(attempts: 12, due_at: Time.current)
    entry.redeliver!(configuration: @configuration)
    assert_equal "failed", entry.reload.state
    assert_equal "attempts_exhausted", entry.failure_code
    entry.update!(state: "pending", expires_at: Time.current, first_delivered_at: 3.days.ago)
    WebhookRedelivery.expire!
    assert_equal "window_expired", entry.reload.failure_code
    assert_equal "failed", SecurityAuditEvent.where(action: "webhook_recovery.expire").last.outcome
    assert_requested request, times: 1
  end

  test "long outages expose a retained gap and terminal evidence is cleaned after thirty days" do
    @checkpoint.update! \
      last_completed_scan_started_at: 4.days.ago, last_completed_credential_revision: 1,
      last_completed_at: 3.days.ago
    api_page([])
    @checkpoint.recover!
    assert_equal 4.days.ago, @checkpoint.reload.gap_started_at
    assert_equal 3.days.ago, @checkpoint.gap_ended_at
    assert_equal "failed", SecurityAuditEvent.where(action: "webhook_recovery.gap").last.outcome
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "remote-guid", event: "push", installation_id: 456, delivered_at: Time.current
    entry.update!(state: "failed", failure_code: "attempts_exhausted", updated_at: 31.days.ago)
    WebhookRedelivery.clear_expired!
    assert_not WebhookRedelivery.exists?(entry.id)
    assert_not_nil @checkpoint.reload.gap_started_at
  end

  test "credential replacement during a metadata page cannot persist or resend stale work" do
    stub_request(:get, "https://api.github.com/app/hook/deliveries")
      .with(query: { per_page: "100" }).to_return do
        GithubAppConfiguration.find(@configuration.id).update!(credential_revision: 2)
        { status: 200, body: JSON.generate([ metadata ]) }
      end
    @checkpoint.recover!
    assert_empty WebhookRedelivery.all
    assert_equal "credentials_changed", @checkpoint.reload.failure_code
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
  end

  test "a metadata response cannot rebind work after its worker lease was replaced" do
    stub_request(:get, "https://api.github.com/app/hook/deliveries")
      .with(query: { per_page: "100" }).to_return do
        WebhookRecoveryCheckpoint.find(@checkpoint.id).update!(lease_token: "new-owner")
        { status: 200, body: JSON.generate([ metadata ]) }
      end
    @checkpoint.recover!
    assert_empty WebhookRedelivery.all
    assert_equal "new-owner", @checkpoint.reload.lease_token
    assert_nil @checkpoint.last_completed_at
    assert_equal 0, @checkpoint.pages
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
  end

  test "unobserved recovery waits for current metadata without extending its original deadline" do
    original_time = 3.days.ago + 30.seconds
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "old-work", event: "push", installation_id: 456,
      delivered_at: original_time, attempt_id: 1234
    entry.update!(state: "requesting", attempts: 5, lease_token: "old-resend", due_at: Time.current)
    @checkpoint.update! \
      cursor: "old-cursor", pages: 1, scan_started_at: Time.current,
      lease_token: "old-lease", enqueue_claim_expires_at: 1.minute.from_now
    @configuration.update!(credential_revision: 2)
    WebhookRecoveryCheckpoint.recover_all!
    assert_nil @checkpoint.reload.cursor
    assert_nil @checkpoint.lease_token
    assert_nil @checkpoint.scan_started_at
    assert_equal 0, @checkpoint.pages
    assert_equal 2, @checkpoint.credential_revision
    assert_equal "pending", entry.reload.state
    assert_equal "credentials_changed", entry.failure_code
    assert_nil entry.lease_token
    assert_equal 1, entry.credential_revision
    assert_equal 5, entry.attempts
    assert_equal original_time + 3.days, entry.expires_at
    assert_not @checkpoint.finish!("old-lease", cursor: "must-not-return")
    api_page([ metadata(guid: "unmatched-guid", status_code: 202) ])
    @checkpoint.recover!
    assert_requested :get, "https://api.github.com/app", times: 1
    assert_nil @checkpoint.reload.failure_code
    entry.redeliver!(configuration: @configuration)
    receipt = webhook_deliveries.create(github_delivery_id: "old-work")
    WebhookRedelivery.record_throttle!(configuration: @configuration, delivery: receipt, installation_id: 456)
    assert_equal 1, entry.reload.credential_revision
    assert_equal 5, entry.attempts
    assert_equal "pending", entry.state
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
    travel 30.seconds
    WebhookRedelivery.expire!
    assert_equal "window_expired", entry.reload.failure_code
    assert_equal "failed", entry.state
    assert_equal "failed", SecurityAuditEvent.where(action: "webhook_recovery.expire").last.outcome
  end

  test "same GUID re-verification across repeated credential changes retains attempts deadline and backoff" do
    first = 2.days.ago
    due = 20.minutes.from_now
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "old-work", event: "push", installation_id: 456,
      delivered_at: first, attempt_id: 1234
    entry.update!(attempts: 10, due_at: due, state: "requesting", lease_token: "old-resend")
    [ 2, 3 ].each do |revision|
      @configuration.update!(credential_revision: revision)
      WebhookRecoveryCheckpoint.recover_all!
      api_page([ metadata(guid: "old-work", id: revision * 1_000, delivered_at: Time.current.iso8601) ])
      @checkpoint.reload.recover!
      assert_equal revision, entry.reload.credential_revision
      assert_equal revision * 1_000, entry.github_attempt_id
      assert_equal first, entry.first_delivered_at
      assert_equal first + 3.days, entry.expires_at
      assert_equal due, entry.due_at
      assert_equal 10, entry.attempts
      assert_equal "pending", entry.state
      assert_nil entry.lease_token
      assert_nil entry.failure_code
    end
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
    entry.update!(attempts: 12, due_at: Time.current)
    entry.redeliver!(configuration: @configuration)
    assert_equal "attempts_exhausted", entry.reload.failure_code
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
  end

  test "a matching GUID cannot rebind different event or installation metadata" do
    entries = %w[changed-event changed-installation missing-installation].map do |guid|
      WebhookRedelivery.record_pending! \
        configuration: @configuration, guid:, event: "push", installation_id: 456,
        delivered_at: 2.days.ago, attempt_id: 1234
    end
    @configuration.update!(credential_revision: 2)
    WebhookRecoveryCheckpoint.recover_all!
    api_page [
      metadata(guid: "changed-event", event: "installation", action: "created"),
      metadata(guid: "changed-installation", installation_id: 789),
      metadata(guid: "missing-installation", installation_id: nil)
    ]
    @checkpoint.reload.recover!
    entries.each do |entry|
      assert_equal "identity_mismatch", entry.reload.failure_code
      assert_equal "failed", entry.state
      assert_equal 1, entry.credential_revision
      assert_equal 0, entry.attempts
    end
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
  end

  test "a superseded credential snapshot cannot complete a pending delivery" do
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "old-work", event: "push", installation_id: 456,
      delivered_at: 2.days.ago, attempt_id: 1234
    GithubAppConfiguration.find(@configuration.id).update!(credential_revision: 2)
    assert_raises(GithubAppConfiguration::Superseded) do
      WebhookRedelivery.complete!(configuration: @configuration, guid: "old-work")
    end
    assert_equal "pending", entry.reload.state
    assert_equal 1, entry.credential_revision
    assert_equal 0, entry.attempts
  end

  test "a replaced local configuration cannot adopt retained recovery even for the same remote App and GUID" do
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "old-work", event: "push", installation_id: 456,
      delivered_at: 2.days.ago, attempt_id: 1234
    @configuration.destroy!
    replacement = github_app_configurations.create_installed(github_app_id: @configuration.github_app_id)
    WebhookRecoveryCheckpoint.recover_all!
    assert_equal "failed", entry.reload.state
    assert_equal "app_changed", entry.failure_code
    api_page([ metadata(guid: "old-work") ])
    WebhookRecoveryCheckpoint.find_by!(github_app_configuration_id: replacement.id).recover!
    assert_equal [ @configuration.id ], WebhookRedelivery.where(github_delivery_id: "old-work").pluck(:github_app_configuration_id)
    assert_equal 0, entry.reload.attempts
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
  end

  test "App reset during metadata retrieval cannot create work or reactivate repositories" do
    actor = users.create(hub_admin: true)
    browser_session = actor.sessions.create!(fresh_authorized_at: Time.current)
    repository = repositories.create
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "remote-guid", event: "push", installation_id: 456,
      delivered_at: 2.days.ago, attempt_id: 5678
    original = ENV["REPLICA_BOOTSTRAP_SECRET"]
    ENV["REPLICA_BOOTSTRAP_SECRET"] = "synthetic"
    stub_request(:get, "https://api.github.com/app/hook/deliveries")
      .with(query: { per_page: "100" }).to_return do
        @configuration.administration.reset! \
          actor:, browser_session:, expected_version: @configuration.lock_version,
          confirmation: GithubAppConfiguration::Administration::RESET_PHRASE
        { status: 200, body: JSON.generate([ metadata ]) }
      end
    @checkpoint.recover!
    assert_equal [ entry.id ], WebhookRedelivery.pluck(:id)
    assert_nil GithubAppConfiguration.current
    assert_equal "removed", repository.reload.installation_state
    assert_equal 1, SessionRevocation.current.generation
    WebhookRecoveryCheckpoint.recover_all!
    assert_equal "app_changed", entry.reload.failure_code
    assert_equal "failed", entry.state
    assert_equal 0, entry.attempts
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
  ensure
    ENV["REPLICA_BOOTSTRAP_SECRET"] = original
  end

  test "ordinary scans keep mixed and equal-boundary entries but stop before older history" do
    boundary = 10.minutes.ago
    @checkpoint.update! \
      last_completed_scan_started_at: boundary, last_completed_credential_revision: 1,
      last_completed_at: 8.minutes.ago
    api_page \
      [
        metadata(guid: "older-success", delivered_at: (boundary - 1.second).iso8601, status_code: 202),
        metadata(guid: "new-failure"),
        metadata(guid: "equal-boundary", delivered_at: boundary.iso8601)
      ],
      cursor: "boundary"
    api_page \
      [ metadata(guid: "covered-success", delivered_at: (boundary - 1.second).iso8601, status_code: 202) ],
      request_cursor: "boundary",
      cursor: "older-history"

    @checkpoint.recover!

    assert_equal %w[equal-boundary new-failure], WebhookRedelivery.order(:github_delivery_id).pluck(:github_delivery_id)
    assert_nil @checkpoint.reload.cursor
    assert_equal Time.current, @checkpoint.last_completed_scan_started_at
    assert_equal 1, @checkpoint.last_completed_credential_revision
    assert_not_requested \
      :get,
      "https://api.github.com/app/hook/deliveries",
      query: { per_page: "100", cursor: "older-history" }
  end

  test "a multi-job scan uses its start so the next scan notices a new arrival immediately" do
    boundary = 1.hour.ago
    @checkpoint.update! \
      last_completed_scan_started_at: boundary, last_completed_credential_revision: 1,
      last_completed_at: 50.minutes.ago
    10.times do |index|
      delivery = metadata \
        id: index + 1,
        guid: "success-#{index}",
        status_code: 202,
        delivered_at: (boundary + 1.minute).iso8601
      api_page \
        [ delivery ],
        request_cursor: index.zero? ? nil : "page-#{index}",
        cursor: "page-#{index + 1}"
    end
    started = Time.current
    @checkpoint.recover!
    assert_equal "page-10", @checkpoint.reload.cursor
    assert_equal 10, @checkpoint.pages
    assert_equal boundary, @checkpoint.last_completed_scan_started_at

    travel 1.minute
    arrival = Time.current
    api_page([ metadata(guid: "new-arrival", delivered_at: arrival.iso8601) ], cursor: "page-1")
    api_page \
      [ metadata(guid: "old-success", status_code: 202, delivered_at: (boundary - 1.minute).iso8601) ],
      request_cursor: "page-10",
      cursor: "unneeded-history"
    @checkpoint.recover!
    assert_equal started, @checkpoint.reload.last_completed_scan_started_at
    assert_equal Time.current, @checkpoint.last_completed_at
    assert_empty WebhookRedelivery.all

    travel 1.minute
    @checkpoint.recover!
    assert_equal [ "new-arrival" ], WebhookRedelivery.pluck(:github_delivery_id)
    assert_requested \
      :get,
      "https://api.github.com/app/hook/deliveries",
      query: { per_page: "100", cursor: "page-1" }, times: 2
    assert_not_requested \
      :get,
      "https://api.github.com/app/hook/deliveries",
      query: { per_page: "100", cursor: "unneeded-history" }
  end

  test "initial and new-credential scans retain the full history path" do
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "retained-work", event: "push", installation_id: 456,
      delivered_at: 2.days.ago, attempt_id: 1234
    entry.update!(due_at: 20.minutes.from_now)
    api_page([ metadata(guid: "old-success", status_code: 202, delivered_at: 2.days.ago.iso8601) ], cursor: "initial-history")
    api_page([], request_cursor: "initial-history")
    @checkpoint.recover!
    coverage = @checkpoint.reload.last_completed_scan_started_at
    assert_requested \
      :get,
      "https://api.github.com/app/hook/deliveries",
      query: { per_page: "100", cursor: "initial-history" }, times: 1

    travel 1.minute
    @configuration.update!(credential_revision: 2)
    WebhookRecoveryCheckpoint.recover_all!
    assert_equal coverage, @checkpoint.reload.last_completed_scan_started_at
    assert_equal 1, @checkpoint.last_completed_credential_revision
    api_page([ metadata(guid: "old-success", status_code: 202, delivered_at: 2.days.ago.iso8601) ], cursor: "reverification-history")
    api_page \
      [ metadata(guid: "retained-work", id: 5678, delivered_at: entry.first_delivered_at.iso8601) ],
      request_cursor: "reverification-history"
    @checkpoint.recover!
    assert_requested \
      :get,
      "https://api.github.com/app/hook/deliveries",
      query: { per_page: "100", cursor: "reverification-history" }, times: 1
    assert_equal 2, entry.reload.credential_revision
    assert_equal 5678, entry.github_attempt_id
    assert_equal 2, @checkpoint.reload.last_completed_credential_revision
    assert_equal Time.current, @checkpoint.last_completed_scan_started_at
  end

  test "a long scan followed by an outage reports deliveries that expired after its first page" do
    started = Time.current
    api_page([], cursor: "unfinished")
    stub_request(:get, "https://api.github.com/app/hook/deliveries")
      .with(query: { per_page: "100", cursor: "unfinished" }).to_return(status: 503, body: "{}")
    @checkpoint.recover!
    assert_equal started, @checkpoint.reload.scan_started_at
    assert_nil @checkpoint.last_completed_at

    travel 1.day
    api_page([], request_cursor: "unfinished")
    @checkpoint.recover!
    completed = Time.current
    assert_equal started, @checkpoint.reload.last_completed_scan_started_at
    assert_equal completed, @checkpoint.last_completed_at

    travel_to started + 3.days + 2.minutes
    api_page([ metadata(guid: "unseen-expired", delivered_at: (started + 1.minute).iso8601) ])
    @checkpoint.recover!
    assert_equal started, @checkpoint.reload.gap_started_at
    assert_equal started + 2.minutes, @checkpoint.gap_ended_at
    assert_not WebhookRedelivery.exists?(github_delivery_id: "unseen-expired")
    assert_equal Time.current, @checkpoint.last_completed_at
    assert_equal "failed", SecurityAuditEvent.where(action: "webhook_recovery.gap").last.outcome
  end

  private

  def metadata(**overrides)
    { id: 1234, guid: "remote-guid", event: "push", action: nil, delivered_at: Time.current.iso8601,
      installation_id: 456, status_code: 503, redelivery: false }.merge(overrides).stringify_keys
  end

  def stub_app(id: @configuration.github_app_id)
    stub_request(:get, "https://api.github.com/app")
      .with { assert_app_jwt(_1); true }.to_return(status: 200, body: JSON.generate(id:))
  end

  def assert_app_jwt(request)
    token = request.headers.fetch("Authorization").delete_prefix("Bearer ")
    key = OpenSSL::PKey::RSA.new(@configuration.private_key).public_key
    claims = JWT.decode(token, key, true, algorithm: "RS256").first
    assert_equal @configuration.client_id, claims.fetch("iss")
    assert_operator claims.fetch("exp"), :<=, 9.minutes.from_now.to_i
    assert_equal Rails.configuration.x.github_api_version, request.headers["X-Github-Api-Version"]
  end

  def api_page(deliveries, request_cursor: nil, cursor: nil, raw_link: nil)
    query = { per_page: "100" }
    query[:cursor] = request_cursor if request_cursor
    link = raw_link || (cursor && "<https://api.github.com/app/hook/deliveries?per_page=100&cursor=#{CGI.escape(cursor)}>; rel=\"next\"")
    stub_request(:get, "https://api.github.com/app/hook/deliveries")
      .with(query:).to_return(status: 200, body: JSON.generate(deliveries), headers: link ? { "Link" => link } : {})
  end
end
