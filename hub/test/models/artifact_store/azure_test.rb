require "test_helper"
require_relative "../../support/artifact_store_contract"

class ArtifactStore::AzureTest < ActiveSupport::TestCase
  include ArtifactStoreContract

  setup do
    @client = FakeClient.new
    @artifact_store = ArtifactStore.new(adapter: ArtifactStore::Azure.new(client: @client))
  end

  test "leaves failed upload blocks private" do
    source = Object.new
    reads = 0
    source.define_singleton_method(:read) do |_length|
      reads += 1
      raise IOError, "interrupted" if reads > 1

      "partial"
    end

    assert_raises(IOError) do
      artifact_store.write("builds/1/interrupted.txt", source:)
    end

    assert_not artifact_store.exist?("builds/1/interrupted.txt")
    assert_predicate @client, :uncommitted_blocks?
  end

  test "continues paginated nested listings" do
    @client.pages = [
      [ [ "builds/1/a.txt" ], "next" ],
      [ [ "builds/1/b.txt" ], nil ]
    ]

    assert_equal [ "builds/1/a.txt", "builds/1/b.txt" ], artifact_store.list("builds/1")
  end

  private

  attr_reader :artifact_store

  class FakeClient
    attr_writer :pages

    def initialize
      @blobs = {}
      @blocks = Hash.new { |hash, key| hash[key] = {} }
      @lock = Mutex.new
    end

    def put_block(name, block_id:, body:)
      lock.synchronize { blocks[name][block_id] = body }
    end

    def commit_blocks(name, block_ids:)
      lock.synchronize do
        raise ArtifactStore::AlreadyExists if blobs.key?(name)

        blobs[name] = block_ids.map { blocks.fetch(name).fetch(_1) }.join
      end
    end

    def read(name, destination:)
      bytes = lock.synchronize { blobs[name] }
      raise ArtifactStore::Missing if bytes.nil?

      destination.write(bytes)
    end

    def exist?(name)
      lock.synchronize { blobs.key?(name) }
    end

    def list(prefix:, marker: nil)
      if @pages
        expected_marker = @pages.length == 2 ? nil : "next"
        raise "unexpected marker" if marker != expected_marker

        return @pages.shift
      end

      [ lock.synchronize { blobs.keys.grep(/^#{Regexp.escape(prefix)}/).sort }, nil ]
    end

    def delete(name)
      lock.synchronize { blobs.delete(name) }
    end

    def uncommitted_blocks?
      lock.synchronize { blocks.values.any?(&:any?) }
    end

    private

    attr_reader :blobs, :blocks, :lock
  end
end
