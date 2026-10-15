require "open3"

# Runs one replica-learning command and returns its JSON output.
#
# The child process gets only PATH, HOME, locale, and REPLICA_LEARNING_* variables, plus a
# Copilot token when the caller passes one, so Hub's own secrets never reach the command or the
# modules its configuration names. Its TMPDIR, and its working directory unless the caller names
# one, is a new private directory that Hub removes afterward, even after it stopped the command,
# so state the command cannot clean up, such as the Copilot runtime's, never stays behind.
#
# The command runs in its own process group, which a timeout ends whole, including the Copilot
# runtime it may start. Hub reads at most OUTPUT_LIMIT bytes of its answer and ERROR_LIMIT bytes of
# its errors, and ends the group when the command writes more. Either way, a call returns at most
# STOP_TIME after Hub ends the group, even when the command takes longer to exit.
class Learning::Command
  TIMEOUT = 60.seconds
  # How long Hub waits for a command it ended to exit and let go of its output.
  STOP_TIME = 1.second
  # replica-learning's largest --json answer lists a repository's learnings. It takes about 6 KB
  # for a learning with four comments behind it, and about 20 KB for one with the longest text and
  # 20 comments, so 16 MB holds hundreds of the largest and thousands of the usual.
  OUTPUT_LIMIT = 16.megabytes
  # Standard error carries one error line, or about 3 KB of usage text after a usage error.
  ERROR_LIMIT = 1.megabyte
  # The CLI's numeric contract uses JavaScript safe integers.
  MAX_SAFE_INTEGER = 2**53 - 1
  # Bytes Hub reads from a stream at a time.
  PIECE = 64.kilobytes
  PASSED_VARIABLES = %w[PATH HOME LANG LC_ALL TZ].freeze
  ERROR = /^error \(([a-z_]+)\): (.+)$/
  # How a failure reads when a package replica-learning needs is not installed: its own report of a
  # missing Copilot SDK, or Node's error for any other package.
  MISSING_PACKAGE = /needs @github\/copilot-sdk|Cannot find package '/
  # The message when a failed command printed nothing to explain why.
  NO_MESSAGE = "replica-learning failed."

  # directory is where the command runs; without one it runs in a new empty directory.
  def initialize(directory: nil, timeout: TIMEOUT, node: ENV.fetch("REPLICA_LEARNING_NODE", "node"), cli: Learning.cli_path,
    execution_lock: Learning::ExecutionLock.current)
    @directory = directory
    @timeout = timeout
    @node = node
    @cli = File.expand_path(cli)
    @execution_lock = execution_lock
  end

  # Runs the command with --json and parses its output, or raises Learning::Error.
  def call(*arguments, copilot_token: nil)
    if !File.file?(@cli)
      raise Learning::Error.new \
        "The replica-learning command is not installed here. Run bin/setup to install it.",
        code: "not_installed"
    end

    output, error, status = within_temporary_directory do |temporary|
      run \
        [ @node, @cli.to_s, *arguments.map(&:to_s), "--json" ],
        directory: @directory&.to_s || temporary,
        temporary:,
        copilot_token:
    end
    if !status.success?
      begin
        labeling_result = labeling_result_from_failure(output, arguments)
      rescue JSON::ParserError, Learning::Error => report_error
        raise if report_error.is_a?(Learning::Error) && report_error.code != "unreadable_output"

        primary = failure(error, status)
        unknown_usage_failure = Learning::Error.new \
          "#{primary.message} The failed command's usage is unknown because its report could not be verified.",
          code: primary.code
        raise unknown_usage_failure, cause: primary
      end
      raise failure(error, status, labeling_result:)
    end

    JSON.parse(output)
  rescue JSON::ParserError
    raise Learning::Error.new("replica-learning returned output Hub could not read.", code: "unreadable_output")
  end

  private

  # Runs the block with a new private directory, which Hub removes afterward even when it stopped
  # the command.
  def within_temporary_directory
    temporary = Dir.mktmpdir("replica-learning-")
    yield temporary
  ensure
    FileUtils.rm_rf(temporary) if temporary
  end

  def run(command, directory:, temporary:, copilot_token:)
    inherited = @execution_lock ? { @execution_lock.fileno => @execution_lock } : {}
    input, output, error, waiter = Open3.popen3 \
      environment(copilot_token, temporary),
      *command,
      chdir: directory,
      unsetenv_others: true,
      pgroup: true,
      **inherited
    input.close
    events = Queue.new
    readers = [ [ output, OUTPUT_LIMIT ], [ error, ERROR_LIMIT ] ].map do |stream, limit|
      Thread.new { quietly { read_within(stream, limit, events) } }
    end
    Thread.new { quietly { events << waiter.value } }
    collect(waiter, readers, events)
  rescue Errno::ENOENT
    raise Learning::Error.new \
      "Node.js or the replica-learning command is not installed here.",
      code: "not_installed"
  ensure
    # Open3's block form would also wait here, with no limit, for the command to exit. Closing the
    # pipes ends any reader still waiting, and Process.detach's thread reaps the command whenever
    # it exits.
    [ input, output, error ].compact.each(&:close)
  end

  # Waits until the command exits and both streams end, within the timeout, and returns the output,
  # the errors, and the exit status. When a stream passes its limit or time runs out, it ends the
  # whole group at once and raises, even while a process outside the group holds a stream open.
  def collect(waiter, readers, events)
    deadline = Deadline.new(@timeout)
    (readers.size + 1).times do
      event = events.pop(timeout: deadline.remaining)
      next if event && !event.is_a?(Learning::Error)

      stop(waiter, readers)
      raise event if event

      raise Learning::Error.new \
        "replica-learning did not finish within #{@timeout.to_i} seconds.",
        code: "timeout"
    end
    [ readers[0].value, readers[1].value, waiter.value ]
  end

  # Ends the whole process group, then gives the command and both readers STOP_TIME in all to
  # finish. Killing the group closes the pipes, unless a process outside it holds them. Then they
  # close when Hub returns, which ends the reader still waiting.
  def stop(waiter, readers)
    terminate(waiter.pid)
    stopping = Deadline.new(STOP_TIME)
    [ waiter, *readers ].each { _1.join(stopping.remaining) }
  end

  def environment(copilot_token, temporary)
    passed = ENV.to_h.select { |name, _| PASSED_VARIABLES.include?(name) || name.start_with?("REPLICA_LEARNING_") }
    passed["TMPDIR"] = temporary
    copilot_token ? passed.merge("COPILOT_GITHUB_TOKEN" => copilot_token) : passed
  end

  def quietly
    Thread.current.report_on_exception = false
    yield
  end

  # Reads a stream to its end, piece by piece, and tells events when it ends. Once the stream
  # passes limit bytes, it stops and tells events about one fixed error instead, so a command
  # cannot fill Hub's memory.
  def read_within(stream, limit, events)
    text = String.new(encoding: Encoding::BINARY)
    loop do
      text << stream.readpartial(PIECE)
      next if text.bytesize <= limit

      overflow = Learning::Error.new \
        "replica-learning wrote more output than Hub accepts, so Hub stopped it.",
        code: "output_too_large"
      events << overflow
      return
    end
  rescue EOFError
    events << :ended
    text.force_encoding(Encoding::UTF_8)
  rescue IOError
    # Hub closed the stream after it stopped the command, so nobody waits for this reader.
    nil
  end

  def terminate(pid)
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH
    nil
  end

  # A failed label command can still report model usage and durable progress.
  def labeling_result_from_failure(output, arguments)
    return if arguments.first != "label" || output.empty?

    report = JSON.parse(output)
    counts = %w[considered labeled remaining]
    usage_counts = %w[requests inputTokens outputTokens nanoAiu]
    valid_count = ->(value) { value.is_a?(Integer) && value.between?(0, MAX_SAFE_INTEGER) }
    valid = report.is_a?(Hash) &&
      counts.all? { valid_count.call(report[_1]) } &&
      report["usage"].is_a?(Hash) &&
      usage_counts.all? { valid_count.call(report["usage"][_1]) } &&
      report["models"].is_a?(Array) && report["models"].all? { _1.is_a?(String) } &&
      report["error"].is_a?(Hash) && report["error"]["code"].is_a?(String) &&
      report["error"]["message"].is_a?(String) &&
      %w[progressError cleanupError usageError].all? { !report.key?(_1) || report[_1].is_a?(String) }
    if !valid
      raise Learning::Error.new("replica-learning returned failure output Hub could not read.", code: "unreadable_output")
    end

    report.except("error")
  end

  def failure(error, status, labeling_result: nil)
    # A command can fail before it writes valid UTF-8, so invalid bytes become replacement marks.
    text = error.to_s.scrub.strip
    if MISSING_PACKAGE.match?(text)
      return Learning::Error.new \
        "A package replica-learning needs is not installed. Run bin/setup to install it.",
        code: "not_installed",
        labeling_result:
    end

    match = ERROR.match(text)
    return Learning::Error.new(match[2].strip, code: match[1], labeling_result:) if match

    code = status.exitstatus == 2 ? "invalid_request" : "learning_failed"
    message = text.lines.first.to_s.delete_prefix("error:").strip.presence || NO_MESSAGE
    Learning::Error.new(message, code:, labeling_result:)
  end
end
