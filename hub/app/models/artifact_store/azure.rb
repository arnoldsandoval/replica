require "base64"
require "securerandom"

# Stores retained Build files in one private Azure Blob container.
class ArtifactStore::Azure
  BLOCK_BYTES = 4.megabytes

  # Uses client or creates one for the configured Azure account and container.
  def initialize(account: nil, container: nil, token_provider: nil, client: nil)
    @client = client
    @client ||= Client.new \
      account:,
      container:,
      token_provider: token_provider || ManagedIdentity.new
  end

  # Uploads source without replacing name and returns the bytes written.
  def write(name, source:)
    block_ids = []
    bytes = 0
    upload_id = SecureRandom.hex(16)
    while (chunk = source.read(BLOCK_BYTES))
      break if chunk.empty?

      block_id = Base64.strict_encode64("#{upload_id}#{block_ids.length.to_s.rjust(8, "0")}")
      client.put_block(name, block_id:, body: chunk)
      block_ids << block_id
      bytes += chunk.bytesize
    end
    client.commit_blocks(name, block_ids:)
    bytes
  end

  # Copies name into destination and returns the number of bytes written.
  def read(name, destination:)
    client.read(name, destination:)
  end

  # Reports whether a blob exists with the exact storage name.
  def exist?(name)
    client.exist?(name)
  end

  # Returns sorted blob names equal to or below one storage path.
  def list(prefix)
    exact = client.exist?(prefix) ? [ prefix ] : []
    (exact + list_nested(prefix)).sort
  end

  # Deletes the named blob and every blob below it; reports whether any existed.
  def delete_prefix(prefix)
    names = list(prefix)
    names.each { client.delete(_1) }
    names.any?
  end

  private

  attr_reader :client

  # Returns every blob name below prefix, requesting all available pages.
  def list_nested(prefix)
    names = []
    marker = nil
    loop do
      page, marker = client.list(prefix: "#{prefix}/", marker:)
      names.concat(page)
      break if marker.blank?
    end
    names
  end
end
