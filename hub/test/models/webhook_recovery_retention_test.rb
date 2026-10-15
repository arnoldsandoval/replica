require "test_helper"

class WebhookRecoveryRetentionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    travel_to Time.current.change(usec: 0)
    @configuration = github_app_configurations.create_installed
    @checkpoint = WebhookRecoveryCheckpoint.create! \
      github_app_configuration_id: @configuration.id, github_app_id: @configuration.github_app_id,
      due_at: Time.current
  end

  teardown { travel_back }

  test "minute recovery expires unresolved windows without deleting retained history" do
    receipt = webhook_deliveries.create(github_delivery_id: "old-receipt", created_at: 8.days.ago)
    terminal = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "old-terminal", event: "push", installation_id: 456,
      delivered_at: Time.current
    terminal.update!(state: "failed", updated_at: 31.days.ago)
    expired = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "unresolved", event: "push", installation_id: 456,
      delivered_at: 2.days.ago
    expired.update!(expires_at: Time.current)

    WebhookRecoveryCheckpoint.recover_all!

    assert WebhookDelivery.exists?(receipt.id)
    assert WebhookRedelivery.exists?(terminal.id)
    assert_equal "failed", expired.reload.state
    assert_equal "window_expired", expired.failure_code
  end

  test "hourly cleanup uses indexed batches and keeps recent active and current records" do
    records = 1_001.times.map do |index|
      { github_delivery_id: "old-#{index}", event: "push", payload_sha256: "a" * 64,
        created_at: 8.days.ago, updated_at: 8.days.ago }
    end
    WebhookDelivery.insert_all!(records)
    receipt = webhook_deliveries.create(github_delivery_id: "boundary-receipt", created_at: 7.days.ago)
    terminal = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "old-terminal", event: "push", installation_id: 456,
      delivered_at: Time.current
    terminal.update!(state: "failed", updated_at: 31.days.ago)
    active = WebhookRedelivery.record_pending! \
      configuration: @configuration, guid: "active-work", event: "push", installation_id: 456,
      delivered_at: Time.current
    active.update!(updated_at: 31.days.ago)
    old_checkpoint = WebhookRecoveryCheckpoint.create! \
      github_app_configuration_id: @configuration.id + 1, github_app_id: @configuration.github_app_id,
      due_at: Time.current, updated_at: 31.days.ago
    @checkpoint.update_columns(updated_at: 31.days.ago)
    deletes = []
    subscriber = lambda do |*arguments|
      sql = arguments.last.fetch(:sql)
      deletes << sql if sql.start_with?('DELETE FROM "webhook_deliveries"')
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      WebhookRedelivery.clear_expired!
    end

    assert_equal 2, deletes.size
    assert_equal [ receipt.id ], WebhookDelivery.pluck(:id)
    assert_not WebhookRedelivery.exists?(terminal.id)
    assert WebhookRedelivery.exists?(active.id)
    assert_not WebhookRecoveryCheckpoint.exists?(old_checkpoint.id)
    assert WebhookRecoveryCheckpoint.exists?(@checkpoint.id)
    assert WebhookDelivery.connection.index_exists?(:webhook_deliveries, :created_at)
    %w[development production].each do |environment|
      task = YAML.load_file(Rails.root.join("config/recurring.yml"))
        .fetch(environment).fetch("clear_expired_webhook_history")
      assert_equal "WebhookRedelivery.clear_expired!", task.fetch("command")
      assert_equal "every hour at minute 24", task.fetch("schedule")
    end
  end
end
