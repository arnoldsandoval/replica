require "test_helper"
require "open3"
require "rbconfig"

class PrivateStorageRootTest < ActiveSupport::TestCase
  setup do
    @root = Pathname(Dir.mktmpdir("private-storage-root-"))
    @application = @root.join("app")
    @public = @application.join("public")
    FileUtils.mkdir_p([ @public, @application.join("storage") ])
  end

  teardown do
    FileUtils.rm_rf(@root) if @root
  end

  test "accepts a dedicated directory that does not exist without creating it" do
    root = @application.join("storage/learning")

    validate(root)

    assert_not root.exist?
  end

  test "rejects filesystem application shared storage and public roots" do
    [ @application.ascend.to_a.last, @application, @application.join("storage"), @public, @public.join("learning") ].each do |root|
      error = assert_raises(RuntimeError) { validate(root) }
      assert_includes error.message, "REPLICA_LEARNING_ROOT must be a dedicated directory outside the public web root"
    end
  end

  test "does not mistake a public directory name prefix for a served path" do
    root = @application.join("public-private/learning")

    validate(root)

    assert_not root.exist?
  end

  test "rejects files and symbolic links anywhere in the candidate path" do
    file = @root.join("data.txt")
    file.write("private test data")
    target = @root.join("target").tap(&:mkpath)
    link = @root.join("link")
    File.symlink(target, link)

    [ file, link, link.join("learning") ].each do |root|
      error = assert_raises(RuntimeError) { validate(root) }
      assert_includes error.message, "must name a directory without symbolic links"
    end
    assert_equal "private test data", file.read
  end

  test "rejects a physical path served through a symbolic public root" do
    @public.rmdir
    served = @root.join("served").tap(&:mkpath)
    File.symlink(served, @public)

    error = assert_raises(RuntimeError) { validate(served.join("learning")) }

    assert_includes error.message, "outside the public web root"
  end

  test "keeps the same protection and error name for local artifact storage" do
    error = assert_raises(RuntimeError) { validate(@public.join("builds"), name: "REPLICA_ARTIFACT_ROOT") }

    assert_includes error.message, "REPLICA_ARTIFACT_ROOT must be a dedicated directory"
  end

  test "actual application boot rejects public learning paths with local or Azure artifacts" do
    %w[local azure].each do |backend|
      output, error, status = boot(Rails.public_path.join("learning-private"), backend:)

      assert_not status.success?, output
      assert_includes error, "REPLICA_LEARNING_ROOT must be a dedicated directory outside the public web root"
    end
  end

  test "actual application boot accepts an unused private learning directory with Azure artifacts" do
    root = @root.join("azure-learning")

    output, error, status = boot(root, backend: "azure")

    assert status.success?, error
    assert_includes output, "boot accepted"
    assert_not root.exist?
  end

  private

  # Uses owned fixture directories while exercising the same guard as deployment startup.
  def validate(root, name: "REPLICA_LEARNING_ROOT")
    PrivateStorageRoot.validate!(root, name:, application_root: @application, public_root: @public)
  end

  # A child process checks real initialization without changing this test process's configuration.
  def boot(root, backend:)
    environment = {
      "RAILS_ENV" => "test",
      "SECRET_KEY_BASE_DUMMY" => "1",
      "REPLICA_LOCAL_MODE" => "0",
      "REPLICA_LEARNING_ROOT" => root.to_s,
      "REPLICA_ARTIFACT_STORE" => backend,
      "REPLICA_AZURE_STORAGE_ACCOUNT" => "replicatest",
      "REPLICA_AZURE_STORAGE_CONTAINER" => "builds",
      "REPLICA_AZURE_MANAGED_IDENTITY_CLIENT_ID" => nil
    }
    Open3.capture3 \
      environment, RbConfig.ruby, "-e",
      'require "./config/environment"; puts "boot accepted"',
      chdir: Rails.root.to_s
  end
end
