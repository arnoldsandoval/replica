require "test_helper"
require "timeout"

class Learning::ExecutionLockTest < ActiveSupport::TestCase
  include LearningTestHelpers

  CLI = Rails.root.join("test/fixtures/files/fake-replica-learning.mjs")

  test "serializes worker threads and releases the lock after an exception" do
    entered = Queue.new
    release = Queue.new
    worker = Thread.new do
      Learning::ExecutionLock.synchronize do
        entered << true
        release.pop(timeout: 10) || raise("The test did not release its worker.")
      end
    end
    assert entered.pop(timeout: 5)

    Timeout.timeout(5) { assert_raises(Learning::ExecutionLock::Busy) { Learning::ExecutionLock.synchronize { } } }
    assert_nil Learning::ExecutionLock.current
    release << true
    assert worker.join(5)
    worker.value
    assert_raises(ArgumentError) { Learning::ExecutionLock.synchronize { raise ArgumentError, "Stopped." } }
    assert_nil Learning::ExecutionLock.current
    Learning::ExecutionLock.synchronize do
      descriptor = Learning::ExecutionLock.current
      assert_raises(Learning::ExecutionLock::Busy) { Learning::ExecutionLock.synchronize { } }
      assert_same descriptor, Learning::ExecutionLock.current
    end
    assert Learning::ExecutionLock.synchronize { true }
    assert_equal 0o700, File.stat(Rails.configuration.x.learning_root).mode & 0o777
  ensure
    release&.push(true)
    worker&.join(5)
  end

  test "a surviving SDK writer keeps the lock after its Ruby worker is killed" do
    marker = Rails.configuration.x.learning_root.join("writer")
    release = Rails.configuration.x.learning_root.join("release")
    worker = fork do
      Learning::ExecutionLock.synchronize { Learning::Command.new(cli: CLI).call("hold-lock", marker, release) }
      exit! 0
    end
    Timeout.timeout(10) { sleep 0.01 until marker.file? }
    writer = marker.read.to_i
    Process.kill("KILL", worker)
    Process.wait(worker)
    worker = nil

    assert_raises(Learning::ExecutionLock::Busy) { Learning::ExecutionLock.synchronize { } }
    release.write("Release the owned test writer.")
    wait_for_lock
    writer = nil
  ensure
    stop_process(worker) if worker
    Process.wait(worker) if worker
    stop_process(writer) if writer
  end

  test "a writer that outlives a command timeout keeps the lock until it exits" do
    marker = Rails.configuration.x.learning_root.join("writer")
    release = Rails.configuration.x.learning_root.join("release")
    Learning::ExecutionLock.synchronize do
      command = Learning::Command.new(cli: CLI, timeout: 1.second)
      # Models a writer stuck in kernel I/O after its group was signaled.
      command.define_singleton_method(:terminate) { |_pid| }
      error = assert_raises(Learning::Error) { command.call("hold-lock", marker, release) }
      assert_equal "timeout", error.code
    end
    writer = marker.read.to_i

    assert_raises(Learning::ExecutionLock::Busy) { Learning::ExecutionLock.synchronize { } }
    release.write("Release the owned test writer.")
    wait_for_lock
    released = true
    writer = nil
  ensure
    stop_process(writer || marker.read.to_i) if !released && marker&.file?
  end

  private

  def wait_for_lock
    acquired = false
    Timeout.timeout(5) do
      until acquired
        begin
          acquired = Learning::ExecutionLock.synchronize { true }
        rescue Learning::ExecutionLock::Busy
          sleep 0.01
        end
      end
    end
    assert acquired
  end

  def stop_process(pid)
    Process.kill("KILL", pid)
  rescue Errno::ESRCH
    nil
  end
end
