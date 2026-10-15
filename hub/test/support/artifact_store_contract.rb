require "stringio"

# Exercises behavior required from every artifact storage provider.
module ArtifactStoreContract
  extend ActiveSupport::Concern

  included do
    test "streams object writes and reads" do
      bytes = (" " * 64.kilobytes) + ("a" * 6.kilobytes)

      assert_equal bytes.bytesize, artifact_store.write("builds/1/dist/index.html", source: StringIO.new(bytes))
      assert artifact_store.exist?("builds/1/dist/index.html")

      destination = StringIO.new("".b)
      assert_equal bytes.bytesize, artifact_store.read("builds/1/dist/index.html", destination:)
      assert_equal bytes, destination.string
    end

    test "does not replace an existing object" do
      artifact_store.write("builds/1/dist/index.html", source: StringIO.new("first"))

      assert_raises(ArtifactStore::AlreadyExists) do
        artifact_store.write("builds/1/dist/index.html", source: StringIO.new("second"))
      end

      destination = StringIO.new("".b)
      artifact_store.read("builds/1/dist/index.html", destination:)
      assert_equal "first", destination.string
    end

    test "allows only one concurrent write to create an object" do
      ready = Queue.new
      start = Queue.new
      results = 4.times.map do |index|
        Thread.new do
          ready << true
          start.pop
          artifact_store.write("builds/1/concurrent.txt", source: StringIO.new(index.to_s))
          :created
        rescue ArtifactStore::AlreadyExists
          :existing
        end
      end
      4.times { ready.pop }
      4.times { start << true }

      assert_equal [ :created, :existing, :existing, :existing ], results.map(&:value).sort
    end

    test "removes an incomplete object when a write fails" do
      source = Object.new
      reads = 0
      source.define_singleton_method(:read) do |_length|
        reads += 1
        raise IOError, "interrupted" if reads > 1

        "partial"
      end

      assert_raises(IOError) do
        artifact_store.write("builds/1/dist/index.html", source:)
      end

      assert_not artifact_store.exist?("builds/1/dist/index.html")
    end

    test "stores an object beside nested objects with the same prefix" do
      artifact_store.write("builds/1/dist", source: StringIO.new("file"))
      artifact_store.write("builds/1/dist/index.html", source: StringIO.new("index"))

      assert_equal \
        [ "builds/1/dist", "builds/1/dist/index.html" ],
        artifact_store.list("builds/1/dist")
    end

    test "allows concurrent writes to an object and nested object" do
      ready = Queue.new
      start = Queue.new
      names = [ "builds/1/dist", "builds/1/dist/index.html" ]
      results = names.map do |name|
        Thread.new do
          ready << true
          start.pop
          artifact_store.write(name, source: StringIO.new(name))
          :created
        end
      end
      2.times { ready.pop }
      2.times { start << true }

      assert_equal [ :created, :created ], results.map(&:value)
    end

    test "lists objects at or below one prefix in sorted order" do
      write_objects \
        "builds/1/screenshots/desktop.png" => "screenshot",
        "builds/1/dist/index.html" => "index",
        "builds/10/dist/index.html" => "other"

      assert_equal \
        [ "builds/1/dist/index.html", "builds/1/screenshots/desktop.png" ],
        artifact_store.list("builds/1")
      assert_equal [ "builds/1/screenshots/desktop.png" ], artifact_store.list("builds/1/screenshots/desktop.png")
      assert_empty artifact_store.list("builds/2")
    end

    test "deletes only objects at or below one prefix" do
      write_objects \
        "builds/1/dist/index.html" => "index",
        "builds/1/screenshots/desktop.png" => "screenshot",
        "builds/2/dist/index.html" => "other"

      assert artifact_store.delete_prefix("builds/1")
      assert_empty artifact_store.list("builds/1")
      assert artifact_store.exist?("builds/2/dist/index.html")
      assert_not artifact_store.delete_prefix("builds/3")

      assert artifact_store.delete_prefix("builds/2/dist/index.html")
      assert_not artifact_store.exist?("builds/2/dist/index.html")
    end

    test "reports a missing source object" do
      assert_not artifact_store.exist?("builds/1/missing.txt")
      assert_raises(ArtifactStore::Missing) do
        artifact_store.read("builds/1/missing.txt", destination: StringIO.new("".b))
      end
    end
  end

  private

  # Writes a group of test objects through the provider-neutral interface.
  def write_objects(objects)
    objects.each do |name, bytes|
      artifact_store.write(name, source: StringIO.new(bytes))
    end
  end
end
