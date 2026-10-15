# Keeps Rails's limiter fail-closed when Solid Cache cannot increment a counter.
class SecurityRateLimitCache
  # Other cache operations retain Solid Cache's existing error behavior.
  def self.handle_error(method:, returning:, exception:)
    raise exception if method == :increment

    SolidCache::Store::Failsafe::DEFAULT_ERROR_HANDLER.call(method:, returning:, exception:)
  end
end
