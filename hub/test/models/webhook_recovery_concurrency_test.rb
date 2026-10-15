require "test_helper"
require "timeout"
require_relative "../support/security_rate_limit_store"

# Committed records and independent connections exercise actual admission races.
class WebhookRecoveryConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ActiveJob::TestHelper
  include SecurityRateLimitStore

  setup do
    travel_to Time.current.change(usec: 0)
    use_security_rate_limit_store
    @configuration = github_app_configurations.create_installed
    @prefix = "race-#{SecureRandom.uuid}"
    @body = JSON.generate(
      installation: { id: 456 }, deleted: true,
      repository: { id: 2001, default_branch: "main" }, ref: "refs/heads/prototype/welcome"
    )
    @signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @configuration.webhook_secret, @body)}"
    @checkpoint = WebhookRecoveryCheckpoint.create! \
      github_app_configuration_id: @configuration.id, github_app_id: @configuration.github_app_id,
      due_at: Time.current
  end

  teardown do
    restore_security_rate_limit_store
    WebhookRedelivery.where(github_app_configuration_id: @configuration.id).delete_all
    WebhookDelivery.where("github_delivery_id LIKE ?", "#{@prefix}%").delete_all
    if @repository
      @repository.prototypes.find_each do |prototype|
        prototype.update!(current_build: nil)
        prototype.builds.find_each(&:destroy!)
        prototype.destroy!
      end
      Analytics::Event.where(repository: @repository).delete_all
      @repository.destroy!
    end
    @checkpoint.destroy!
    @configuration.destroy!
    SecurityAuditEvent.where("json_extract(context, '$.github_app_configuration_id') = ?", @configuration.id).delete_all
    travel_back
  end

  test "overlapping real webhook requests admit exactly six hundred new deliveries" do
    # Test routes load lazily; production prepares them before accepting requests.
    route = Rails.application.routes.recognize_path("/github/webhooks", method: :post)
    assert_equal "github_webhooks", route.fetch(:controller)
    ready = Queue.new
    start = Queue.new
    requests = 4.times.map do |worker|
      Thread.new do
        ready << true
        start.pop
        session = ActionDispatch::Integration::Session.new(Rails.application)
        151.times.map do |index|
          session.post "/github/webhooks", params: @body, headers: {
            "Content-Type" => "application/json", "Accept" => "application/json",
            "X-GitHub-Delivery" => "#{@prefix}-#{worker}-#{index}", "X-GitHub-Event" => "push",
            "X-Hub-Signature-256" => @signature
          }
          [ session.response.status, session.response.headers["Retry-After"] ]
        end
      end
    end
    4.times { ready.pop }
    4.times { start << true }
    responses = requests.flat_map(&:value)
    assert_equal 600, responses.count { _1.first == 202 }
    assert_equal 4, responses.count { _1 == [ 429, "60" ] }
    assert_equal 600, WebhookDelivery.where("github_delivery_id LIKE ?", "#{@prefix}%").where.not(processed_at: nil).count
    assert_equal 4, WebhookRedelivery.where(github_app_configuration_id: @configuration.id).count
  ensure
    requests&.each(&:join)
  end

  test "overlapping duplicate receipts invoke admission only once and abandoned claims cannot clear new leases" do
    entered = Queue.new
    finish = Queue.new
    admission_count = 0
    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        GithubWebhook.process! \
          configuration: GithubAppConfiguration.find(@configuration.id), body: @body,
          signature: @signature, event: "push", delivery_id: @prefix do
            admission_count += 1
            entered << true
            finish.pop
            true
          end
      end
    end
    entered.pop
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        GithubWebhook.process! \
          configuration: GithubAppConfiguration.find(@configuration.id), body: @body,
          signature: @signature, event: "push", delivery_id: @prefix do
            admission_count += 1
            true
          end
      end
    end
    second.value
    finish << true
    first.value
    assert_equal 1, admission_count
    assert WebhookDelivery.find_by!(github_delivery_id: @prefix).processed?

    receipt = webhook_deliveries.create(github_delivery_id: "#{@prefix}-stale")
    assert receipt.start_processing!
    receipt.update_columns(processing_started_at: 6.minutes.ago)
    current = WebhookDelivery.find(receipt.id)
    assert current.start_processing!
    receipt.allow_retry!
    assert_not_nil current.reload.processing_token
    assert_not receipt.finish_processing!(build: nil)
    assert current.finish_processing!(build: nil)
  ensure
    finish << true if finish
    [ first, second ].compact.each(&:join)
  end

  test "simultaneous first receipts establish one identity and charge one admission" do
    ready = Queue.new
    start = Queue.new
    admissions = Queue.new
    workers = 4.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          GithubWebhook.process! \
            configuration: GithubAppConfiguration.find(@configuration.id), body: @body,
            signature: @signature, event: "push", delivery_id: @prefix do
              admissions << true
              true
            end
        end
      end
    end
    4.times { ready.pop }
    4.times { start << true }
    workers.each(&:value)
    assert_equal 1, admissions.size
    assert_equal 1, WebhookDelivery.where(github_delivery_id: @prefix).count
    assert WebhookDelivery.find_by!(github_delivery_id: @prefix).processed?
  ensure
    workers&.each(&:join)
  end

  test "simultaneous checkpoint jobs and resend workers send only one attempt outside a transaction" do
    entered = Queue.new
    finish = Queue.new
    app_calls = 0
    stub_request(:get, "https://api.github.com/app").to_return do
      app_calls += 1
      entered << true
      finish.pop
      { status: 200, body: JSON.generate(id: @configuration.github_app_id) }
    end
    stub_request(:get, "https://api.github.com/app/hook/deliveries")
      .with(query: { per_page: "100" }).to_return(status: 200, body: "[]")
    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { WebhookRecoveryCheckpoint.find(@checkpoint.id).recover! }
    end
    entered.pop
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { WebhookRecoveryCheckpoint.find(@checkpoint.id).recover! }
    end
    second.value
    finish << true
    first.value
    assert_equal 1, app_calls
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: @prefix, event: "push", installation_id: 456,
      delivered_at: Time.current, attempt_id: 1234
    entry.update!(due_at: Time.current)
    sent = Queue.new
    complete = Queue.new
    request = stub_request(:post, "https://api.github.com/app/hook/deliveries/1234/attempts").to_return do
      assert_equal 0, WebhookRedelivery.connection.open_transactions
      sent << true
      complete.pop
      { status: 202, body: "" }
    end
    sender = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        WebhookRedelivery.find(entry.id).redeliver!(configuration: GithubAppConfiguration.find(@configuration.id))
      end
    end
    sent.pop
    competitor = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        WebhookRedelivery.find(entry.id).redeliver!(configuration: GithubAppConfiguration.find(@configuration.id))
      end
    end
    competitor.value
    WebhookRedelivery.complete!(configuration: @configuration, guid: @prefix)
    complete << true
    sender.value
    assert_requested request, times: 1
    assert_equal "succeeded", entry.reload.state
    assert_nil entry.lease_token
  ensure
    finish << true if finish
    complete << true if complete
    [ first, second, sender, competitor ].compact.each(&:join)
  end

  test "only the new authenticated scan rebinds a GUID while superseded metadata is paused" do
    first_delivered_at = 2.days.ago
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: @prefix, event: "push", installation_id: 456,
      delivered_at: first_delivered_at, attempt_id: 1234
    entry.update!(attempts: 4, due_at: Time.current)
    paused = Queue.new
    resume = Queue.new
    connections = Queue.new
    stub_request(:get, "https://api.github.com/app")
      .to_return(status: 200, body: JSON.generate(id: @configuration.github_app_id))
    old_connection = nil
    stub_request(:get, "https://api.github.com/app/hook/deliveries")
      .with(query: { per_page: "100" }).to_return do
        connection = ActiveRecord::Base.connection.object_id
        if connection == old_connection
          assert_not ApplicationRecord.connection.transaction_open?
          paused << true
          Timeout.timeout(10) { resume.pop }
        end
        attempt = connection == old_connection ? 1234 : 5678
        { status: 200, body: JSON.generate([
          { id: attempt, guid: @prefix, event: "push", action: nil, installation_id: 456,
            delivered_at: Time.current.iso8601, status_code: 503 }
        ]) }
      end
    request = stub_request(:post, "https://api.github.com/app/hook/deliveries/5678/attempts")
      .to_return(status: 202, body: "")
    old_worker = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        old_connection = connection.object_id
        connections << connection.object_id
        WebhookRecoveryCheckpoint.find(@checkpoint.id).recover!
      end
    end
    Timeout.timeout(10) { paused.pop }
    @configuration.update!(credential_revision: 2)
    WebhookRecoveryCheckpoint.recover_all!
    assert_equal 1, entry.reload.credential_revision
    assert_equal "credentials_changed", entry.failure_code
    new_worker = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connections << connection.object_id
        WebhookRecoveryCheckpoint.find(@checkpoint.id).recover!
      end
    end
    Timeout.timeout(10) { new_worker.value }
    completion = @checkpoint.reload.last_completed_at
    assert_not_nil completion
    resume << true
    Timeout.timeout(10) { old_worker.value }
    assert_equal 2, 2.times.map { connections.pop }.uniq.size
    assert_requested :get, "https://api.github.com/app", times: 2
    assert_requested request, times: 1
    assert_not_requested :post, "https://api.github.com/app/hook/deliveries/1234/attempts"
    assert_equal 2, entry.reload.credential_revision
    assert_equal 5678, entry.github_attempt_id
    assert_equal 5, entry.attempts
    assert_equal first_delivered_at, entry.first_delivered_at
    assert_equal first_delivered_at + 3.days, entry.expires_at
    assert_equal "waiting", entry.state
    assert_equal completion, @checkpoint.reload.last_completed_at
    assert_nil @checkpoint.failure_code
  ensure
    resume << true if resume
    [ old_worker, new_worker ].compact.each(&:join)
  end

  test "credential rotation between the final check and installation lookup cannot resend with new credentials" do
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: @prefix, event: "push", installation_id: 456,
      delivered_at: Time.current, attempt_id: 1234
    entry.update!(due_at: Time.current)
    paused = Queue.new
    resume = Queue.new
    original_key = @configuration.private_key
    worker = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        snapshot = GithubAppConfiguration.find(@configuration.id)
        work = WebhookRedelivery.find(entry.id)
        lookup = work.method(:stale_installation?)
        lookups = 0
        work.define_singleton_method(:stale_installation?) do |configuration|
          lookups += 1
          if lookups == 2
            paused << connection.object_id
            Timeout.timeout(10) { resume.pop }
          end
          lookup.call(configuration)
        end
        connection.cache { work.redeliver!(configuration: snapshot) }
        [ snapshot.credential_revision, snapshot.private_key == original_key ]
      end
    end
    old_connection = Timeout.timeout(10) { paused.pop }
    assert_not_equal old_connection, ActiveRecord::Base.connection.object_id
    @configuration.update! \
      credential_revision: 2,
      private_key: OpenSSL::PKey::RSA.generate(2048).to_pem
    resume << true
    assert_equal [ 1, true ], Timeout.timeout(10) { worker.value }
    assert_not_requested :post, %r{/app/hook/deliveries/\d+/attempts}
    assert_equal "pending", entry.reload.state
    assert_equal "credentials_changed", entry.failure_code
    assert_equal 1, entry.credential_revision
    assert_equal 1, entry.attempts
    assert_nil entry.lease_token
  ensure
    resume << true if resume
    worker&.join
  end

  test "a newer push during a recovered branch lookup cannot lose its current Build" do
    repository = repositories.create
    @repository = repository
    payload = {
      installation: { id: 456 }, repository: { id: repository.github_id, default_branch: "main" },
      ref: "refs/heads/prototype/recovered", before: "a" * 40, after: "b" * 40, deleted: false
    }
    body = JSON.generate(payload)
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @configuration.webhook_secret, body)}"
    WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "#{@prefix}-old", event: "push", installation_id: 456,
      delivered_at: Time.current, attempt_id: 1234
    paused = Queue.new
    resume = Queue.new
    stub_request(:post, "https://api.github.com/app/installations/456/access_tokens")
      .to_return(status: 201, body: JSON.generate(token: "installation-token", expires_at: 1.hour.from_now.iso8601))
    stub_request(:get, "https://api.github.com/repos/#{repository.github_path}/git/ref/heads/prototype/recovered")
      .to_return do
        assert_not ApplicationRecord.connection.transaction_open?
        paused << true
        Timeout.timeout(10) { resume.pop }
        { status: 200, body: JSON.generate(object: { sha: "b" * 40 }) }
      end
    worker = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        GithubWebhook.process! \
          configuration: GithubAppConfiguration.find(@configuration.id), body:, signature:,
          event: "push", delivery_id: "#{@prefix}-old"
      end
    end
    Timeout.timeout(10) { paused.pop }
    newer_body = JSON.generate(payload.merge(before: "b" * 40, after: "c" * 40))
    newer_signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @configuration.webhook_secret, newer_body)}"
    newer = GithubWebhook.process! \
      configuration: @configuration, body: newer_body, signature: newer_signature,
      event: "push", delivery_id: "#{@prefix}-new"
    resume << true
    older = Timeout.timeout(10) { worker.value }
    assert_equal newer, newer.prototype.reload.current_build
    assert_equal "b" * 40, older.commit_sha
    assert_equal "superseded", older.state
  ensure
    resume << true if resume
    worker&.join
  end

  test "a head moving away and back during recovery cannot be replaced by the older push" do
    repository = repositories.create
    @repository = repository
    prototype = prototypes.create(repository:, branch_name: "prototype/recovered-aba")
    current = builds.create_successful \
      prototype:, number: 1, commit_sha: "c" * 40, previous_commit_sha: "b" * 40
    other = builds.create_successful \
      prototype:, number: 2, commit_sha: "d" * 40, previous_commit_sha: current.commit_sha
    repository.build_discoveries.record! \
      branch_name: prototype.branch_name, commit_sha: current.commit_sha, branch_head: true
    payload = {
      installation: { id: 456 }, repository: { id: repository.github_id, default_branch: "main" },
      ref: "refs/heads/#{prototype.branch_name}", before: "a" * 40, after: "b" * 40, deleted: false
    }
    body = JSON.generate(payload)
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @configuration.webhook_secret, body)}"
    WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "#{@prefix}-old", event: "push", installation_id: 456,
      delivered_at: Time.current, attempt_id: 1234
    paused = Queue.new
    resume = Queue.new
    stub_request(:post, "https://api.github.com/app/installations/456/access_tokens")
      .to_return(status: 201, body: JSON.generate(token: "installation-token", expires_at: 1.hour.from_now.iso8601))
    stub_request(:get, "https://api.github.com/repos/#{repository.github_path}/git/ref/heads/#{prototype.branch_name}")
      .to_return do
        assert_not ApplicationRecord.connection.transaction_open?
        paused << true
        Timeout.timeout(10) { resume.pop }
        { status: 200, body: JSON.generate(object: { sha: payload.fetch(:after) }) }
      end
    worker = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        GithubWebhook.process! \
          configuration: GithubAppConfiguration.find(@configuration.id), body:, signature:,
          event: "push", delivery_id: "#{@prefix}-old"
      end
    end
    Timeout.timeout(10) { paused.pop }
    [
      [ "to-other", current.commit_sha, other ],
      [ "back-to-current", other.commit_sha, current ]
    ].each do |guid, before, expected|
      live_body = JSON.generate(payload.merge(before:, after: expected.commit_sha))
      live_signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @configuration.webhook_secret, live_body)}"
      observed = GithubWebhook.process! \
        configuration: @configuration, body: live_body, signature: live_signature,
        event: "push", delivery_id: "#{@prefix}-#{guid}"
      assert_equal expected.id, observed.id
      assert_equal expected.id, prototype.reload.current_build_id
    end
    assert_equal current.id, prototype.reload.current_build_id
    assert_equal 2, prototype.builds.count
    assert_equal 2, prototype.builds.maximum(:number)
    assert_equal 3, prototype.head_observation_revision

    resume << true
    older = Timeout.timeout(10) { worker.value }

    assert_equal current.id, prototype.reload.current_build_id
    assert_equal 3, prototype.head_observation_revision
    assert_equal payload.fetch(:after), older.commit_sha
    assert_equal "successful", current.reload.state
    assert_equal "superseded", older.state
  ensure
    resume << true if resume
    worker&.join
  end

  test "an unchanged live head observation prevents an older recovery from becoming current" do
    repository = repositories.create
    @repository = repository
    prototype = prototypes.create(repository:, branch_name: "prototype/recovered-unchanged")
    current = builds.create_successful \
      prototype:, number: 1, commit_sha: "c" * 40, previous_commit_sha: "b" * 40
    repository.build_discoveries.record! \
      branch_name: prototype.branch_name, commit_sha: current.commit_sha, branch_head: true
    payload = {
      installation: { id: 456 }, repository: { id: repository.github_id, default_branch: "main" },
      ref: "refs/heads/#{prototype.branch_name}", before: "a" * 40, after: "b" * 40, deleted: false
    }
    body = JSON.generate(payload)
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @configuration.webhook_secret, body)}"
    WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "#{@prefix}-old", event: "push", installation_id: 456,
      delivered_at: Time.current, attempt_id: 1234
    paused = Queue.new
    resume = Queue.new
    stub_request(:post, "https://api.github.com/app/installations/456/access_tokens")
      .to_return(status: 201, body: JSON.generate(token: "installation-token", expires_at: 1.hour.from_now.iso8601))
    request = stub_request(:get, "https://api.github.com/repos/#{repository.github_path}/git/ref/heads/#{prototype.branch_name}")
      .to_return do
        assert_not ApplicationRecord.connection.transaction_open?
        paused << true
        Timeout.timeout(10) { resume.pop }
        { status: 200, body: JSON.generate(object: { sha: payload.fetch(:after) }) }
      end
    worker = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connection.cache do
          GithubWebhook.process! \
            configuration: GithubAppConfiguration.find(@configuration.id), body:, signature:,
            event: "push", delivery_id: "#{@prefix}-old"
        end
      end
    end
    Timeout.timeout(10) { paused.pop }
    live_body = JSON.generate(payload.merge(before: "b" * 40, after: current.commit_sha))
    live_signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @configuration.webhook_secret, live_body)}"
    repeated = GithubWebhook.process! \
      configuration: @configuration, body: live_body, signature: live_signature,
      event: "push", delivery_id: "#{@prefix}-unchanged"
    assert_equal current.id, repeated.id
    assert_equal current.id, prototype.reload.current_build_id
    assert_equal 2, prototype.head_observation_revision

    resume << true
    older = Timeout.timeout(10) { worker.value }

    assert_equal current.id, prototype.reload.current_build_id
    assert_equal 2, prototype.head_observation_revision
    assert_equal "superseded", older.state
    assert_requested request, times: 1
  ensure
    resume << true if resume
    worker&.join
  end

  test "a superseded resend worker cannot complete work or reset its consumed attempt" do
    entry = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: @prefix, event: "push", installation_id: 456,
      delivered_at: 2.days.ago, attempt_id: 1234
    entry.update!(due_at: Time.current)
    sent = Queue.new
    resume = Queue.new
    request = stub_request(:post, "https://api.github.com/app/hook/deliveries/1234/attempts").to_return do
      assert_equal 0, WebhookRedelivery.connection.open_transactions
      sent << ActiveRecord::Base.connection.object_id
      Timeout.timeout(10) { resume.pop }
      { status: 202, body: "" }
    end
    worker = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        WebhookRedelivery.find(entry.id).redeliver!(configuration: GithubAppConfiguration.find(@configuration.id))
      end
    end
    old_connection = Timeout.timeout(10) { sent.pop }
    assert_not_equal old_connection, ActiveRecord::Base.connection.object_id
    due = entry.reload.due_at
    expires_at = entry.expires_at
    @configuration.update!(credential_revision: 2)
    WebhookRecoveryCheckpoint.recover_all!
    resume << true
    Timeout.timeout(10) { worker.value }
    assert_requested request, times: 1
    assert_equal "pending", entry.reload.state
    assert_equal "credentials_changed", entry.failure_code
    assert_equal 1, entry.credential_revision
    assert_equal 1, entry.attempts
    assert_equal due, entry.due_at
    assert_equal expires_at, entry.expires_at
    assert_nil entry.lease_token
  ensure
    resume << true if resume
    worker&.join
  end
end
