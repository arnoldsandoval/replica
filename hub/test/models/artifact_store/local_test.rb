require "test_helper"
require "tmpdir"
require_relative "../../support/artifact_store_contract"

class ArtifactStore::LocalTest < ActiveSupport::TestCase
  include ArtifactStoreContract

  setup do
    @root = Pathname(Dir.mktmpdir("replica-artifact-store-"))
    @artifact_store = ArtifactStore.new(adapter: ArtifactStore::Local.new(root: @root))
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "rejects symbolic links anywhere inside the store" do
    outside = Pathname(Dir.mktmpdir("replica-artifact-outside-"))
    outside.join("index.html").binwrite("index")
    FileUtils.mkdir_p(@root)
    File.symlink(outside, @root.join("linked"))

    assert_raises(ArtifactStore::InvalidObject) do
      artifact_store.read("linked/index.html", destination: StringIO.new("".b))
    end
    assert_raises(ArtifactStore::InvalidObject) do
      artifact_store.write("linked/new.txt", source: StringIO.new("new"))
    end
    assert_raises(ArtifactStore::InvalidObject) do
      artifact_store.list("linked")
    end
    assert_raises(ArtifactStore::InvalidObject) do
      artifact_store.delete_prefix("linked/index.html")
    end
    assert_equal "index", outside.join("index.html").binread
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  test "never lists an incomplete implementation file" do
    FileUtils.mkdir_p(@root.join(ArtifactStore::INTERNAL_SEGMENT))
    @root.join(ArtifactStore::INTERNAL_SEGMENT, "object-orphan.tmp").binwrite("partial")

    assert_empty artifact_store.list("temporary")
    assert_raises(ArtifactStore::InvalidName) do
      artifact_store.list("#{ArtifactStore::INTERNAL_SEGMENT}/object-orphan.tmp")
    end
  end

  test "rejects a symbolic link or file used as the storage root" do
    outside = Pathname(Dir.mktmpdir("replica-artifact-outside-"))
    linked_root = @root.join("linked-root")
    file_root = @root.join("file-root")
    File.symlink(outside, linked_root)
    file_root.binwrite("not a directory")

    assert_raises(ArtifactStore::InvalidObject) do
      ArtifactStore::Local.new(root: linked_root)
    end
    assert_raises(ArtifactStore::InvalidObject) do
      ArtifactStore::Local.new(root: file_root)
    end
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  test "rejects a storage root beneath a file" do
    file = @root.join("file")
    file.binwrite("not a directory")

    assert_raises(ArtifactStore::InvalidObject) do
      ArtifactStore::Local.new(root: file.join("artifacts"))
    end
  end

  test "removes an object when synchronizing its directory fails" do
    adapter = ArtifactStore::Local.new(root: @root)
    adapter.define_singleton_method(:fsync_directory) { |_directory| raise IOError, "sync failed" }
    store = ArtifactStore.new(adapter:)

    assert_raises(IOError) do
      store.write("builds/1/dist/index.html", source: StringIO.new("index"))
    end

    assert_not store.exist?("builds/1/dist/index.html")
  end

  private

  attr_reader :artifact_store
end
