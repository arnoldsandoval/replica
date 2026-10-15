require "test_helper"

class Learning::CommandTest < ActiveSupport::TestCase
  CLI = Rails.root.join("test/fixtures/files/fake-replica-learning.mjs")

  test "passes only allowlisted variables and the Copilot token it was given" do
    with_environment("SECRET_KEY_BASE" => "hub-secret", "REPLICA_LEARNING_DEBUG" => "1") do
      result = command.call("environment", copilot_token: "copilot-user-token")

      assert_equal "copilot-user-token", result.fetch("token")
      assert_includes result.fetch("variables"), "REPLICA_LEARNING_DEBUG"
      assert_not_includes result.fetch("variables"), "SECRET_KEY_BASE"
    end
    assert_nil command.call("environment").fetch("token")
  end

  test "runs in its directory, or in a new empty one that it removes" do
    Dir.mktmpdir do |directory|
      assert_equal \
        File.realpath(directory),
        File.realpath(Learning::Command.new(directory:, cli: CLI).call("directory").fetch("directory"))
    end
    ran_in = command.call("directory").fetch("directory")
    assert_not File.exist?(ran_in)
  end

  test "resolves a relative command override before changing the working directory" do
    relative = CLI.relative_path_from(Pathname.pwd).to_s
    with_environment("REPLICA_LEARNING_CLI" => relative) do
      temporary = Learning::Command.new.call("directory").fetch("directory")
      assert_not File.exist?(temporary)

      Dir.mktmpdir do |directory|
        result = Learning::Command.new(directory:).call("directory")

        assert_equal File.realpath(directory), File.realpath(result.fetch("directory"))
      end
    end
  end

  test "removes the command's temporary files, even in its own directory and after Hub stops it" do
    Dir.mktmpdir do |directory|
      error = assert_raises(Learning::Error) do
        Learning::Command.new(directory:, cli: CLI, timeout: 1.second).call("stash")
      end

      assert_equal "timeout", error.code
      stashed = File.read(File.join(directory, "stashed"))
      assert_not File.exist?(stashed), "Copilot's state stayed in #{stashed}"
    ensure
      FileUtils.rm_rf(stashed) if stashed
    end
  end

  test "reports the store's error code and message" do
    error = assert_raises(Learning::Error) { command.call("copilot", "status", copilot_token: "no-copilot-token") }

    assert_equal "unauthorized", error.code
    assert_equal "Copilot refused the request: 403", error.message
    assert_equal "invalid_input", assert_raises(Learning::Error) { command.call("unknown") }.code
  end

  test "keeps a failed labeling command's reported usage without hiding its failure" do
    error = assert_raises(Learning::Error) { command.call("label", "partial") }

    assert_equal "copilot_unavailable", error.code
    assert_equal "The next model request failed.", error.message
    assert_equal 1, error.labeling_result.dig("usage", "requests")
    assert_equal 5_000_000, error.labeling_result.dig("usage", "nanoAiu")
    assert_equal 3, error.labeling_result.fetch("remaining")
    assert_not error.labeling_result.key?("error")
  end

  test "reports uncertain progress while keeping known labeling usage" do
    error = assert_raises(Learning::Error) { command.call("label", "partial-uncertain") }

    assert_equal "copilot_unavailable", error.code
    assert_includes error.message, "Pending comment counts could not be verified."
    assert_includes error.message, "The next model request failed."
    assert_equal 1, error.labeling_result.dig("usage", "requests")
    assert_equal "Pending comment counts could not be verified.", error.labeling_result.fetch("progressError")
  end

  test "keeps the command failure when its usage report cannot be verified" do
    %w[partial-invalid partial-unsafe partial-invalid-note].each do |mode|
      error = assert_raises(Learning::Error) { command.call("label", mode) }

      assert_equal "copilot_unavailable", error.code
      assert_match(/usage.*unknown/i, error.message)
      assert_nil error.labeling_result
    end
  end

  test "malformed partial output never masks the command's authorization refusal" do
    %w[partial-auth-invalid partial-auth-garbled].each do |mode|
      error = assert_raises(Learning::Error) { command.call("label", mode) }

      assert_equal "unauthorized", error.code
      assert_match(/usage.*unknown/i, error.message)
      assert_nil error.labeling_result
      assert_equal "unauthorized", error.cause.code
    end
  end

  test "keeps the original refusal and known usage while reporting unknown failure usage" do
    error = assert_raises(Learning::Error) { command.call("label", "partial-usage") }

    assert_equal "unauthorized", error.code
    assert_includes error.message, "Some usage from the failed request is unknown."
    assert_includes error.message, "The next model request failed."
    assert_equal 5_000_000, error.labeling_result.dig("usage", "nanoAiu")
    assert_equal "Some usage from the failed request is unknown.", error.labeling_result.fetch("usageError")
  end

  test "keeps the original refusal and usage while reporting a cleanup failure" do
    error = assert_raises(Learning::Error) { command.call("label", "partial-cleanup") }

    assert_equal "unauthorized", error.code
    assert_includes error.message, "The next model request failed."
    assert_includes error.message, "The Copilot runtime could not be closed."
    assert_equal 1, error.labeling_result.dig("usage", "requests")
    assert_equal "The Copilot runtime could not be closed.", error.labeling_result.fetch("cleanupError")
  end

  test "ends the whole command when it runs past its time" do
    started = Time.current
    error = assert_raises(Learning::Error) { Learning::Command.new(cli: CLI, timeout: 1.second).call("wait") }

    assert_equal "timeout", error.code
    assert_operator Time.current - started, :<, 10.seconds
  end

  test "stops waiting soon after its time even when a process outside its group keeps the output open" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Learning::Error) { Learning::Command.new(cli: CLI, timeout: 1.second).call("linger") }

    assert_equal "timeout", error.code
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 4
  end

  test "returns soon after its time even when the command outlives the signal that ends it" do
    command = Learning::Command.new(cli: CLI, timeout: 1.second)
    end_group = lambda do |pid|
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end
    stuck = []
    # A process in uninterruptible kernel I/O can outlive SIGKILL for a while. This one dies 5 seconds late.
    command.define_singleton_method(:terminate) do |pid|
      stuck << pid
      Thread.new do
        sleep 5
        end_group.call(pid)
      end
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(Learning::Error) { command.call("wait") }

    assert_equal "timeout", error.code
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1 + Learning::Command::STOP_TIME + 1
  ensure
    stuck&.each { end_group.call(_1) }
  end

  test "reads an answer that arrives in many pieces" do
    text = command.call("flood", "stdout", 1.megabyte.to_s).fetch("text")

    assert_equal [ 1.megabyte, 2.megabytes ], [ text.length, text.bytesize ]
  end

  test "stops a command that writes more than Hub reads to standard output or standard error" do
    { "stdout" => Learning::Command::OUTPUT_LIMIT, "stderr" => Learning::Command::ERROR_LIMIT }.each do |stream, limit|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(Learning::Error) do
        Learning::Command.new(cli: CLI, timeout: 10.seconds).call("flood", stream, (limit / 2 + 1.megabyte).to_s)
      end

      assert_equal "output_too_large", error.code, stream
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5, stream
    end
  end

  test "stops a command that floods standard error while a process outside its group holds standard output" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Learning::Error) do
      Learning::Command.new(cli: CLI, timeout: 10.seconds)
        .call("flood", "stderr", (Learning::Command::ERROR_LIMIT / 2 + 1.megabyte).to_s, "held")
    end

    assert_equal "output_too_large", error.code
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 4
  end

  test "refuses output it cannot read and a missing command" do
    assert_equal "unreadable_output", assert_raises(Learning::Error) { command.call("garbled") }.code
    missing = Learning::Command.new(cli: CLI, node: "replica-node-that-does-not-exist")
    assert_equal "not_installed", assert_raises(Learning::Error) { missing.call("environment") }.code
  end

  test "reports a missing replica-learning entry point as not installed" do
    missing = Learning::Command.new(cli: CLI.dirname.join("replica-learning-that-does-not-exist.mjs"))

    error = assert_raises(Learning::Error) { missing.call("copilot", "status") }

    assert_equal "not_installed", error.code
  end

  test "says to run bin/setup when replica-learning cannot find a package it needs" do
    %w[sdk package].each do |missing|
      error = assert_raises(Learning::Error) { command.call("missing", missing) }

      assert_equal "not_installed", error.code, missing
      assert_equal "A package replica-learning needs is not installed. Run bin/setup to install it.", error.message, missing
    end
  end

  test "reports a failure whose error output is not valid UTF-8" do
    error = assert_raises(Learning::Error) { command.call("garbled-error") }

    assert_equal "learning_failed", error.code
    assert_predicate error.message, :valid_encoding?
  end

  private

  def command
    Learning::Command.new(cli: CLI)
  end

  def with_environment(values)
    previous = values.to_h { [ _1, ENV[_1] ] }
    values.each { ENV[_1] = _2 }
    yield
  ensure
    previous.each { ENV[_1] = _2 }
  end
end
