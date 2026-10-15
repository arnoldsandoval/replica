require "test_helper"
require "stringio"

class ArtifactStoreTest < ActiveSupport::TestCase
  test "rejects unsafe or ambiguous object names" do
    store = ArtifactStore.new(adapter: Object.new)
    invalid_names = [ "", "/absolute", "../outside", "path/../outside", "path/./file", "path//file",
      "path/", "path\\file", "path\0file", "café", ".replica-internal/file", "a" * 256,
      "a" * 1_025, ([ "a" ] * 24).join("/"), "\xff".b.force_encoding(Encoding::UTF_8) ]

    invalid_names.each do |name|
      assert_raises(ArtifactStore::InvalidName) do
        store.exist?(name)
      end
    end
  end

  test "rejects invalid or unrelated names returned by an adapter" do
    adapter = Object.new
    store = ArtifactStore.new(adapter:)

    adapter.define_singleton_method(:list) { |_prefix| [ "builds/10/file.txt" ] }
    assert_raises(ArtifactStore::InvalidObject) { store.list("builds/1") }

    adapter.define_singleton_method(:list) { |_prefix| [ "builds/1/../outside" ] }
    assert_raises(ArtifactStore::InvalidObject) { store.list("builds/1") }
  end
end
