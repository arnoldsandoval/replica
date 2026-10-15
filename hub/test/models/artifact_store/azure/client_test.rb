require "test_helper"
require "stringio"

class ArtifactStore::Azure::ClientTest < ActiveSupport::TestCase
  ENDPOINT = "http://azure.example.test/account"
  CONTAINER_URL = "#{ENDPOINT}/artifacts"

  setup do
    token_provider = Object.new
    token_provider.define_singleton_method(:token) { "storage-token" }
    @client = ArtifactStore::Azure::Client.new \
      account: "account",
      container: "artifacts",
      token_provider:,
      endpoint: ENDPOINT
  end

  test "uploads blocks and publishes a create-only blob" do
    block = stub_request(:put, /#{Regexp.escape(CONTAINER_URL)}\/builds\/1\/file.txt\?.*blockid=/)
      .with(headers: { "Authorization" => "Bearer storage-token" })
      .to_return(status: 201)
    commit = stub_request(:put, /#{Regexp.escape(CONTAINER_URL)}\/builds\/1\/file.txt\?.*comp=blocklist/)
      .with \
        headers: { "If-None-Match" => "*" },
        body: /<Uncommitted>YmxvY2s=<\/Uncommitted>/
    commit.to_return(status: 201)

    @client.put_block("builds/1/file.txt", block_id: "YmxvY2s=", body: "contents")
    @client.commit_blocks("builds/1/file.txt", block_ids: [ "YmxvY2s=" ])

    assert_requested block
    assert_requested commit
  end

  test "maps a failed create-only condition to an existing object" do
    stub_request(:put, /comp=blocklist/).to_return(status: 412)

    assert_raises(ArtifactStore::AlreadyExists) do
      @client.commit_blocks("builds/1/file.txt", block_ids: [ "YmxvY2s=" ])
    end
  end

  test "publishes an empty blob without uploading blocks" do
    request = stub_request(:put, "#{CONTAINER_URL}/builds/1/empty.txt")
      .with(headers: { "If-None-Match" => "*", "x-ms-blob-type" => "BlockBlob" }, body: "")
      .to_return(status: 201)

    @client.commit_blocks("builds/1/empty.txt", block_ids: [])

    assert_requested request
  end

  test "streams reads and reports missing objects" do
    stub_request(:get, "#{CONTAINER_URL}/builds/1/file.txt")
      .to_return(status: 200, body: "contents", headers: { "Content-Length" => "8" })
    destination = StringIO.new("".b)

    assert_equal 8, @client.read("builds/1/file.txt", destination:)
    assert_equal "contents", destination.string

    stub_request(:get, "#{CONTAINER_URL}/builds/1/missing.txt")
      .to_return(status: 404, headers: { "x-ms-error-code" => "BlobNotFound" })
    assert_raises(ArtifactStore::Missing) do
      @client.read("builds/1/missing.txt", destination: StringIO.new("".b))
    end
  end

  test "rejects an object response that ends before its declared size" do
    stub_request(:get, "#{CONTAINER_URL}/builds/1/file.txt")
      .to_return(status: 200, body: "short", headers: { "Content-Length" => "10" })

    assert_raises(ArtifactStore::TemporaryError) do
      @client.read("builds/1/file.txt", destination: StringIO.new("".b))
    end
  end

  test "distinguishes exact existence from missing objects" do
    stub_request(:head, "#{CONTAINER_URL}/builds/1/file.txt").to_return(status: 200)
    stub_request(:head, "#{CONTAINER_URL}/builds/1/missing.txt")
      .to_return(status: 404, headers: { "x-ms-error-code" => "BlobNotFound" })

    assert @client.exist?("builds/1/file.txt")
    assert_not @client.exist?("builds/1/missing.txt")
  end

  test "returns listing pages and continuation markers" do
    request = stub_request(:get, "#{CONTAINER_URL}?comp=list&prefix=builds%2F1%2F&restype=container")
      .to_return(status: 200, body: <<~XML)
        <?xml version="1.0" encoding="utf-8"?>
        <EnumerationResults>
          <Blobs><Blob><Name>builds/1/dist/index.html</Name></Blob></Blobs>
          <NextMarker>next page</NextMarker>
        </EnumerationResults>
      XML

    names, marker = @client.list(prefix: "builds/1/")

    assert_equal [ "builds/1/dist/index.html" ], names
    assert_equal "next page", marker
    assert_requested request
  end

  test "rejects malformed object listings" do
    stub_request(:get, /comp=list/).to_return(status: 200, body: "not xml")

    assert_raises(ArtifactStore::InvalidObject) do
      @client.list(prefix: "builds/1/")
    end
  end

  test "escapes object path segments without escaping separators" do
    request = stub_request(:head, "#{CONTAINER_URL}/builds/1/a%20file.txt").to_return(status: 200)

    assert @client.exist?("builds/1/a file.txt")
    assert_requested request
  end

  test "wraps transport failures without exposing the token" do
    stub_request(:head, "#{CONTAINER_URL}/builds/1/file.txt").to_timeout

    error = assert_raises(ArtifactStore::TemporaryError) do
      @client.exist?("builds/1/file.txt")
    end

    assert_not_includes error.message, "storage-token"
  end

  test "does not treat a missing container as a missing blob" do
    stub_request(:head, "#{CONTAINER_URL}/builds/1/file.txt")
      .to_return(status: 404, headers: { "x-ms-error-code" => "ContainerNotFound" })

    assert_raises(ArtifactStore::InvalidObject) do
      @client.exist?("builds/1/file.txt")
    end
  end

  test "reports Azure error codes without exposing response messages" do
    stub_request(:head, "#{CONTAINER_URL}/builds/1/file.txt")
      .to_return \
        status: 403,
        headers: { "x-ms-error-code" => "AuthorizationPermissionMismatch" },
        body: "secret service details"

    error = assert_raises(ArtifactStore::Error) do
      @client.exist?("builds/1/file.txt")
    end

    assert_includes error.message, "AuthorizationPermissionMismatch"
    assert_not_includes error.message, "secret service details"
  end
end
