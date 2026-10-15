require "test_helper"
require "open3"
require "tmpdir"

# Checks startup mode selection without starting another development container.
class DevcontainerTest < ActiveSupport::TestCase
  test "dev starts local mode and prepares the example by default" do
    calls = dev_calls(mode: nil)

    assert_equal 4, calls.length
    assert_match(/env REPLICA_LOCAL_MODE=1 bin\/rails db:prepare\z/, calls[1])
    assert_match(/env REPLICA_LOCAL_MODE=1 bin\/rails runner LocalDevelopment.seed_example!\z/, calls[2])
    assert_match(/env REPLICA_LOCAL_MODE=1 bin\/dev\z/, calls[3])
  end

  test "zero starts GitHub-backed development without seeding" do
    calls = dev_calls(mode: "0")

    assert_equal 2, calls.length
    assert_match(/env REPLICA_LOCAL_MODE=0 bin\/dev\z/, calls[1])
  end

  test "false starts GitHub-backed development without seeding" do
    calls = dev_calls(mode: "false")

    assert_equal 2, calls.length
    assert_match(/env REPLICA_LOCAL_MODE=0 bin\/dev\z/, calls[1])
  end

  private

  def dev_calls(mode:)
    Dir.mktmpdir("devcontainer-test-") do |directory|
      docker = File.join(directory, "docker")
      calls = File.join(directory, "calls")
      File.write(docker, <<~'SH')
        #!/bin/sh
        if [ "$1" = image ]; then exit 0; fi
        printf '%s\n' "$*" >> "$DOCKER_CALLS"
      SH
      File.chmod(0o755, docker)

      output, error, status = Open3.capture3(
        {
          "PATH" => "#{directory}:#{ENV.fetch('PATH')}",
          "DOCKER_CALLS" => calls,
          "REPLICA_LOCAL_MODE" => mode
        },
        Rails.root.join("bin/devcontainer").to_s, "dev"
      )
      assert status.success?, "#{output}\n#{error}"
      File.readlines(calls).map(&:strip)
    end
  end
end
