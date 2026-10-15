module SecurityRateLimitStore
  include ActiveJob::TestHelper

  # Uses production's durable counter implementation, not an in-process test cache.
  def use_security_rate_limit_store
    @previous_cache = Rails.cache
    # Test fixtures own database transactions, so housekeeping uses the test queue.
    Rails.cache = SolidCache::Store.new \
      expiry_method: :job, error_handler: SecurityRateLimitCache.method(:handle_error)
    Rails.cache.clear
  end

  def restore_security_rate_limit_store
    Rails.cache.clear
    Rails.cache = @previous_cache
  end

  def assert_security_throttle(seconds)
    assert_response :too_many_requests
    assert_equal seconds.to_s, response.headers["Retry-After"]
    assert_equal "private, no-store", response.headers["Cache-Control"]
    payload = JSON.parse(response.body)
    assert_equal "rate_limited", payload.fetch("code")
    assert_equal seconds, payload.fetch("retryAfter")
    assert_equal [ I18n.t("security_rate_limits.exceeded", seconds:) ], payload.fetch("errors")
  end
end
