require "test_helper"
require_relative "../support/security_rate_limit_store"

class WebhookRateLimitsTest < ActionDispatch::IntegrationTest
  include SecurityRateLimitStore

  setup do
    use_security_rate_limit_store
    @configuration = github_app_configurations.create_installed
    @body = JSON.generate(
      installation: { id: 456 }, deleted: true,
      repository: { id: 2001, default_branch: "main" }, ref: "refs/heads/prototype/welcome"
    )
    travel_to Time.current.change(usec: 0)
  end

  teardown do
    restore_security_rate_limit_store
    travel_back
  end

  test "exactly six hundred new verified deliveries fit and a throttled GUID competes again" do
    600.times do |index|
      deliver("push-#{index}")
      assert_response :accepted
    end
    2.times do
      deliver("throttled")
      assert_security_throttle(60)
    end
    receipt = WebhookDelivery.find_by!(github_delivery_id: "throttled")
    recovery = WebhookRedelivery.find_by!(github_delivery_id: "throttled")
    assert_not receipt.processed?
    assert_nil receipt.processing_started_at
    assert_nil receipt.processing_token
    assert_equal "pending", recovery.state
    assert_nil recovery.github_attempt_id
    assert_equal @configuration.github_app_id, recovery.github_app_id

    deliver("push-0")
    assert_response :accepted
    assert_equal 602, Rails.cache.read("rate-limit:security:webhooks:hub")
    deliver("push-0", body: JSON.generate(installation: { id: 456 }, deleted: false))
    assert_response :unauthorized
    assert_equal 602, Rails.cache.read("rate-limit:security:webhooks:hub")

    travel 60.seconds
    deliver("throttled")
    assert_response :accepted
    assert receipt.reload.processed?
    assert_equal "succeeded", recovery.reload.state
    assert_equal 1, Rails.cache.read("rate-limit:security:webhooks:hub")
  end

  test "unsupported invalid-signature and wrong-installation deliveries cannot spend verified allowance" do
    3.times do |index|
      deliver("invalid-#{index}", signature: "sha256=wrong")
      assert_response :unauthorized
      deliver("unsupported-#{index}", event: "issues")
      assert_response :accepted
      deliver("other-installation-#{index}", body: JSON.generate(installation: { id: 999 }, deleted: true))
      assert_response :unauthorized
    end
    assert_nil Rails.cache.read("rate-limit:security:webhooks:hub")
    assert_empty WebhookDelivery.all
    assert_empty WebhookRedelivery.all
    @configuration.destroy!
    deliver("no-app")
    assert_response :unauthorized
    assert_empty WebhookRedelivery.all
  end

  private

  def deliver(guid, body: @body, event: "push", signature: nil)
    signature ||= "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @configuration.webhook_secret, body)}"
    post github_webhooks_path, params: body, headers: {
      "Content-Type" => "application/json", "Accept" => "application/json",
      "X-GitHub-Delivery" => guid, "X-GitHub-Event" => event, "X-Hub-Signature-256" => signature
    }
  end
end
