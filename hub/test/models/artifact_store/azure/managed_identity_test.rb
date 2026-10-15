require "test_helper"

class ArtifactStore::Azure::ManagedIdentityTest < ActiveSupport::TestCase
  ENDPOINT = "http://identity.example.test/token"

  test "requests and caches an Azure Storage token" do
    body = JSON.generate \
      access_token: "storage-token",
      expires_on: 1.hour.from_now.to_i.to_s
    request = stub_request(:get, ENDPOINT)
      .with \
        query: {
          "api-version" => "2019-08-01",
          "client_id" => "11111111-1111-1111-1111-111111111111",
          "resource" => "https://storage.azure.com/"
        },
        headers: { "X-Identity-Header" => "identity-secret" }
    request.to_return \
      status: 200,
      body: body
    identity = ArtifactStore::Azure::ManagedIdentity.new \
      endpoint: ENDPOINT,
      identity_header: "identity-secret",
      client_id: "11111111-1111-1111-1111-111111111111"

    assert_equal "storage-token", identity.token
    assert_equal "storage-token", identity.token
    assert_requested request, times: 1
  end

  test "requests a token from an Azure VM managed identity" do
    body = JSON.generate \
      access_token: "storage-token",
      expires_on: 1.hour.from_now.to_i.to_s
    request = stub_request(:get, ENDPOINT)
      .with \
        query: {
          "api-version" => "2018-02-01",
          "resource" => "https://storage.azure.com/"
        },
        headers: { "Metadata" => "true" }
    request.to_return \
      status: 200,
      body: body
    identity = ArtifactStore::Azure::ManagedIdentity.new \
      endpoint: nil,
      identity_header: nil,
      vm_endpoint: ENDPOINT,
      client_id: nil

    assert_equal "storage-token", identity.token
    assert_requested request
  end

  test "requires complete Container Apps identity settings" do
    identity = ArtifactStore::Azure::ManagedIdentity.new \
      endpoint: ENDPOINT,
      identity_header: nil,
      client_id: nil

    assert_raises(ArtifactStore::InvalidObject) { identity.token }
  end

  test "does not use the VM endpoint with only a Container Apps identity header" do
    identity = ArtifactStore::Azure::ManagedIdentity.new \
      endpoint: nil,
      identity_header: "identity-secret",
      vm_endpoint: ENDPOINT,
      client_id: nil

    assert_raises(ArtifactStore::InvalidObject) { identity.token }
    assert_not_requested :get, ENDPOINT
  end

  test "requires a hosting platform identity endpoint" do
    identity = ArtifactStore::Azure::ManagedIdentity.new \
      endpoint: nil,
      identity_header: nil,
      vm_endpoint: nil,
      client_id: nil

    assert_raises(ArtifactStore::InvalidObject) { identity.token }
  end

  test "rejects malformed token responses" do
    stub_request(:get, /#{Regexp.escape(ENDPOINT)}/)
      .to_return(status: 200, body: JSON.generate(access_token: "token"))
    identity = ArtifactStore::Azure::ManagedIdentity.new \
      endpoint: ENDPOINT,
      identity_header: "identity-secret",
      client_id: nil

    assert_raises(ArtifactStore::InvalidObject) { identity.token }
  end

  test "rejects an empty token expiration and retries retrieval" do
    request = stub_request(:get, /#{Regexp.escape(ENDPOINT)}/)
      .to_return(status: 200, body: JSON.generate(access_token: "token", expires_on: ""))
    identity = ArtifactStore::Azure::ManagedIdentity.new \
      endpoint: ENDPOINT,
      identity_header: "identity-secret",
      client_id: nil

    2.times { assert_raises(ArtifactStore::InvalidObject) { identity.token } }
    assert_requested request, times: 2
  end

  test "treats identity endpoint timeouts as temporary" do
    stub_request(:get, /#{Regexp.escape(ENDPOINT)}/).to_return(status: 408)
    identity = ArtifactStore::Azure::ManagedIdentity.new \
      endpoint: ENDPOINT,
      identity_header: "identity-secret",
      client_id: nil

    assert_raises(ArtifactStore::TemporaryError) { identity.token }
  end
end
