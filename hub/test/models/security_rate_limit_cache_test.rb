require "test_helper"

class SecurityRateLimitCacheTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    @key = "security-counter-test:#{SecureRandom.uuid}"
    @options = { expiry_method: :job, error_handler: SecurityRateLimitCache.method(:handle_error) }
  end

  teardown do
    SolidCache::Store.new(@options).delete(@key)
  end

  test "independent stores atomically increment a cold counter using separate database connections" do
    ready = Queue.new
    start = Queue.new
    connections = Queue.new
    threads = 4.times.map do
      Thread.new do
        SolidCache::Record.connection_pool.with_connection do |connection|
          connections << connection.object_id
          store = SolidCache::Store.new(@options)
          ready << true
          start.pop
          30.times.map { store.increment(@key, 1, expires_in: 1.minute) }
        end
      end
    end
    4.times { ready.pop }
    4.times { start << true }
    assert_equal (1..120).to_a, threads.flat_map(&:value).sort
    assert_equal 4, 4.times.map { connections.pop }.uniq.size
    assert_equal 120, SolidCache::Store.new(@options).read(@key)
  ensure
    threads&.each(&:join)
  end

  test "increment retains the first expiry instead of extending the window" do
    travel_to Time.current.change(usec: 0)
    first = SolidCache::Store.new(@options)
    second = SolidCache::Store.new(@options)
    assert_equal 1, first.increment(@key, 1, expires_in: 1.minute)
    travel 59.seconds
    assert_equal 2, second.increment(@key, 1, expires_in: 1.minute)
    travel 1.second
    assert_equal 1, first.increment(@key, 1, expires_in: 1.minute)
  ensure
    travel_back
  end

  test "the production error handler raises rather than letting Rails admit a nil counter" do
    store = SolidCache::Store.new(@options)
    original = SolidCache::Entry.method(:lock_and_write)
    SolidCache::Entry.define_singleton_method(:lock_and_write) { |*| raise ActiveRecord::LockWaitTimeout }
    assert_raises(ActiveRecord::LockWaitTimeout) { store.increment(@key, 1, expires_in: 1.minute) }
  ensure
    SolidCache::Entry.define_singleton_method(:lock_and_write, original) if original
  end
end
