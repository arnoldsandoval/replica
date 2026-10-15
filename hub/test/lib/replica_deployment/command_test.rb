require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class ReplicaDeployment::CommandTest < ActiveSupport::TestCase
  test "init writes generated configuration with private permissions" do
    Dir.mktmpdir do |directory|
      deploy_root = prepare_deployment(directory)
      fake_bin = prepare_fake_docker(directory)
      docker_log = File.join(directory, "docker.log")
      environment = {
        "FAKE_DOCKER_LOG" => docker_log,
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
      }

      stdout, stderr, status = Open3.capture3 \
        environment,
        File.join(deploy_root, "replica"),
        "init",
        "Hub.Example.com"

      assert status.success?, stderr
      assert_includes stdout, "Configuration created."
      assert_includes stdout, "*.preview.hub.example.com"
      assert_equal "600", File.stat(File.join(deploy_root, ".env")).mode.to_s(8).last(3)
      assert_includes File.read(File.join(deploy_root, ".env")), "REPLICA_HUB_ORIGIN=https://hub.example.com"
      assert_includes \
        File.read(docker_log),
        "run --rm ghcr.io/github/replica-hub:1 bin/replica-deployment-config generate"
    end
  end

  test "init refuses to replace existing configuration" do
    Dir.mktmpdir do |directory|
      deploy_root = prepare_deployment(directory)
      File.write(File.join(deploy_root, ".env"), "existing=true\n")

      _stdout, stderr, status = Open3.capture3 \
        File.join(deploy_root, "replica"),
        "init",
        "hub.example.com"

      assert_not status.success?
      assert_includes stderr, "Configuration already exists"
      assert_equal "existing=true\n", File.read(File.join(deploy_root, ".env"))
    end
  end

  test "down preserves the persistent volume" do
    Dir.mktmpdir do |directory|
      deploy_root = prepare_deployment(directory)
      fake_bin = prepare_fake_docker(directory)
      File.write(File.join(deploy_root, ".env"), "REPLICA_HUB_ORIGIN=https://hub.example.com\n")
      environment = {
        "FAKE_DOCKER_LOG" => File.join(directory, "docker.log"),
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
      }

      _stdout, stderr, status = Open3.capture3 \
        environment,
        File.join(deploy_root, "replica"),
        "down"

      assert status.success?, stderr
      invocation = File.read(File.join(directory, "docker.log"))
      assert_includes invocation, "compose --file #{deploy_root}/compose.yml"
      assert_not_includes invocation, "--volumes"
    end
  end

  test "status reports the container health" do
    Dir.mktmpdir do |directory|
      deploy_root = prepare_deployment(directory)
      fake_bin = prepare_fake_docker(directory)
      File.write(File.join(deploy_root, ".env"), "REPLICA_HUB_ORIGIN=https://hub.example.com\n")
      environment = { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}" }

      stdout, stderr, status = Open3.capture3 \
        environment,
        File.join(deploy_root, "replica"),
        "status"

      assert status.success?, stderr
      assert_equal "Replica Hub is healthy.\n", stdout
    end
  end

  test "up reports startup failure and recent logs" do
    Dir.mktmpdir do |directory|
      deploy_root = prepare_deployment(directory)
      fake_bin = prepare_fake_docker(directory)
      File.write(File.join(deploy_root, ".env"), "REPLICA_HUB_ORIGIN=https://hub.example.com\n")
      environment = {
        "FAKE_DOCKER_HEALTH" => "unhealthy",
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
      }

      _stdout, stderr, status = Open3.capture3 \
        environment,
        File.join(deploy_root, "replica"),
        "up"

      assert_not status.success?
      assert_includes stderr, "Replica Hub failed to start."
      assert_includes stderr, "Application failed during startup."
    end
  end

  test "up starts the installed image without pulling an update" do
    Dir.mktmpdir do |directory|
      deploy_root = prepare_deployment(directory)
      fake_bin = prepare_fake_docker(directory)
      docker_log = File.join(directory, "docker.log")
      File.write(File.join(deploy_root, ".env"), "REPLICA_HUB_ORIGIN=https://hub.example.com\n")
      environment = {
        "FAKE_DOCKER_LOG" => docker_log,
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
      }

      _stdout, stderr, status = Open3.capture3 \
        environment,
        File.join(deploy_root, "replica"),
        "up"

      assert status.success?, stderr
      invocation = File.read(docker_log)
      compose_command = "compose --file #{deploy_root}/compose.yml --project-directory #{deploy_root}"
      assert_includes invocation, "#{compose_command} up --detach"
      assert_not_includes invocation, "#{compose_command} pull"
    end
  end

  test "update reports the installed image version" do
    Dir.mktmpdir do |directory|
      deploy_root = prepare_deployment(directory)
      fake_bin = prepare_fake_docker(directory)
      docker_log = File.join(directory, "docker.log")
      File.write(File.join(deploy_root, ".env"), "REPLICA_HUB_ORIGIN=https://hub.example.com\n")
      environment = {
        "FAKE_DOCKER_LOG" => docker_log,
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
      }

      stdout, stderr, status = Open3.capture3 \
        environment,
        File.join(deploy_root, "replica"),
        "update"

      assert status.success?, stderr
      assert_equal "Replica Hub 1.2.3 is up to date.\n", stdout
      compose_command = "compose --file #{deploy_root}/compose.yml --project-directory #{deploy_root}"
      assert_includes File.read(docker_log), "#{compose_command} pull"
    end
  end

  private

  # Copies the release files so each test observes an isolated deployment.
  def prepare_deployment(directory)
    deploy_root = File.join(directory, "deploy")
    FileUtils.mkdir_p(deploy_root)
    FileUtils.cp Rails.root.join("deploy/compose.yml"), deploy_root
    FileUtils.cp Rails.root.join("deploy/replica"), deploy_root
    FileUtils.chmod(0o755, File.join(deploy_root, "replica"))
    deploy_root
  end

  # Provides the Docker responses the wrapper needs without touching the host daemon.
  def prepare_fake_docker(directory)
    fake_bin = File.join(directory, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write \
      File.join(fake_bin, "docker"),
      <<~SH
        #!/bin/sh
        if [ -n "${FAKE_DOCKER_LOG:-}" ]; then printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"; fi
        if [ "$1" = "inspect" ]; then
          case "$*" in
            *org.opencontainers.image.version*) printf '%s\n' "1.2.3" ;;
            *) printf '%s\n' "${FAKE_DOCKER_HEALTH:-healthy}" ;;
          esac
        fi
        if [ "$1" = "compose" ] && [ "$6" = "ps" ]; then printf '%s\n' "container-id"; fi
        if [ "$1" = "compose" ] && [ "$6" = "logs" ]; then
          printf '%s\n' "Application failed during startup." >&2
        fi
        if [ "$1" = "run" ]; then
          cat <<'ENV'
        REPLICA_HUB_ORIGIN=https://hub.example.com
        REPLICA_PREVIEW_ORIGIN_TEMPLATE=https://b{build_id}.preview.hub.example.com
        REPLICA_SHARE_PREVIEW_ORIGIN_TEMPLATE=https://s{build_id}.preview.hub.example.com
        REPLICA_BOOTSTRAP_SECRET=setup-code
        SECRET_KEY_BASE=secret
        REPLICA_DATABASE_ENCRYPTION_PRIMARY_KEY=primary
        REPLICA_DATABASE_ENCRYPTION_DETERMINISTIC_KEY=deterministic
        REPLICA_DATABASE_ENCRYPTION_KEY_DERIVATION_SALT=salt
        ENV
        fi
      SH
    FileUtils.chmod(0o755, File.join(fake_bin, "docker"))
    fake_bin
  end
end
