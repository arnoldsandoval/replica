require "base64"
require "digest"
require "json"
require "net/http"
require "rexml/document"
require "securerandom"
require "time"

# Sends authenticated requests to one Azure Blob container.
class ArtifactStore::Azure::Client
  API_VERSION = "2023-11-03"

  # Saves the account, container, and credentials used for Azure requests.
  def initialize(account:, container:, token_provider:, endpoint: nil)
    @account = account
    @container = container
    @token_provider = token_provider
    @endpoint = endpoint || "https://#{account}.blob.core.windows.net"
  end

  # Uploads one part of name; Azure keeps it hidden until all parts are joined.
  def put_block(name, block_id:, body:)
    request \
      :put,
      name,
      query: { comp: "block", blockid: block_id },
      body:,
      headers: { "Content-MD5" => Base64.strict_encode64(Digest::MD5.digest(body)) },
      expected_status: 201
  end

  # Combines uploaded pieces into a blob if its name is unused.
  def commit_blocks(name, block_ids:)
    return put_empty_blob(name) if block_ids.empty?

    body = block_list_xml(block_ids)
    request \
      :put,
      name,
      query: { comp: "blocklist" },
      body:,
      headers: { "Content-Type" => "application/xml", "If-None-Match" => "*" },
      expected_status: 201,
      already_exists: true
  end

  # Copies name into destination and returns the number of bytes written.
  def read(name, destination:)
    bytes = 0
    request(:get, name, expected_status: 200, missing: true) do |response|
      expected_bytes = response["content-length"]
      if !expected_bytes.to_s.match?(/\A\d+\z/)
        raise ArtifactStore::InvalidObject, "Azure Blob Storage returned an invalid object length"
      end
      response.read_body do |chunk|
        bytes += destination.write(chunk)
      end
      if bytes != expected_bytes.to_i
        raise ArtifactStore::TemporaryError, "Azure Blob Storage object download ended early"
      end
    end
    destination.flush if destination.respond_to?(:flush)
    bytes
  end

  # Reports whether one exact blob exists.
  def exist?(name)
    request(:head, name, expected_status: 200, missing: true)
    true
  rescue ArtifactStore::Missing
    false
  end

  # Returns names beginning with prefix and Azure's value for the next page.
  def list(prefix:, marker: nil)
    query = { restype: "container", comp: "list", prefix: }
    query[:marker] = marker if marker.present?
    response = request(:get, nil, query:, expected_status: 200)
    document = REXML::Document.new(response.body)
    if document.root&.name != "EnumerationResults"
      raise ArtifactStore::InvalidObject, "Azure Blob Storage returned an invalid object listing"
    end
    names = REXML::XPath.match(document, "/EnumerationResults/Blobs/Blob/Name").map(&:text)
    if names.any?(&:nil?)
      raise ArtifactStore::InvalidObject, "Azure Blob Storage returned an invalid object listing"
    end
    next_marker = REXML::XPath.first(document, "/EnumerationResults/NextMarker")&.text
    [ names, next_marker ]
  rescue REXML::ParseException
    raise ArtifactStore::InvalidObject, "Azure Blob Storage returned an invalid object listing"
  end

  # Deletes name and returns true, including when it was already deleted.
  def delete(name)
    request(:delete, name, expected_status: 202, missing: true)
    true
  rescue ArtifactStore::Missing
    true
  end

  private

  attr_reader :account, :container, :endpoint, :token_provider

  # Sends one Azure request and raises for a failed response or connection.
  def request(
    method,
    name,
    query: nil,
    body: nil,
    headers: {},
    expected_status:,
    missing: false,
    already_exists: false,
    &response_block
  )
    uri = request_uri(name, query:)
    request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
    request["Authorization"] = "Bearer #{token_provider.token}"
    request["x-ms-date"] = Time.now.httpdate
    request["x-ms-version"] = API_VERSION
    request["x-ms-client-request-id"] = SecureRandom.uuid
    headers.each { |key, value| request[key] = value }
    request.body = body if body

    if response_block
      return perform(request, uri) do |streamed_response|
        check_response(streamed_response, expected_status:, name:, missing:, already_exists:)
        response_block.call(streamed_response)
      end
    end

    response = perform(request, uri)
    check_response(response, expected_status:, name:, missing:, already_exists:)
    response
  rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
    raise ArtifactStore::TemporaryError, "Azure Blob Storage request failed: #{error.message}"
  end

  # Sends request with fixed timeouts and allows its body to be read in chunks.
  def perform(request, uri, &block)
    Net::HTTP.start \
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: 5,
      read_timeout: 30 do |http|
      block ? http.request(request, &block) : http.request(request)
    end
  end

  # Builds a container URL for name and rejects unsafe endpoint settings.
  def request_uri(name, query:)
    base = URI.parse(endpoint)
    valid_scheme = base.is_a?(URI::HTTPS) || (Rails.env.test? && base.is_a?(URI::HTTP))
    if !valid_scheme || base.host.blank? || base.userinfo.present? || base.query.present? || base.fragment.present?
      raise ArtifactStore::InvalidObject, "Azure Blob endpoint must be an HTTPS origin"
    end

    escaped_container = escape_segment(container)
    escaped_name = name&.split("/")&.map { escape_segment(_1) }&.join("/")
    path = [ base.path.delete_suffix("/"), escaped_container, escaped_name ].compact.join("/")
    base.path = path.start_with?("/") ? path : "/#{path}"
    base.query = URI.encode_www_form(query) if query
    base
  rescue URI::InvalidURIError
    raise ArtifactStore::InvalidObject, "Azure Blob endpoint must be an HTTPS origin"
  end

  # Escapes one container or file-name part so it can appear in a URL.
  def escape_segment(segment)
    URI::DEFAULT_PARSER.escape(segment.to_s, /[^A-Za-z0-9\-._~]/)
  end

  # Lists the uploaded parts in the XML format Azure requires.
  def block_list_xml(block_ids)
    blocks = block_ids.map { "<Uncommitted>#{_1}</Uncommitted>" }.join
    %(<?xml version="1.0" encoding="utf-8"?><BlockList>#{blocks}</BlockList>)
  end

  # Creates an empty blob without replacing an existing blob.
  def put_empty_blob(name)
    request \
      :put,
      name,
      body: "",
      headers: { "x-ms-blob-type" => "BlockBlob", "If-None-Match" => "*" },
      expected_status: 201,
      already_exists: true
  end

  # Returns for an expected status or raises the matching storage error.
  def check_response(response, expected_status:, name:, missing:, already_exists:)
    status = response.code.to_i
    return if Array(expected_status).include?(status)
    code = azure_error_code(response)
    if missing && status == 404 && code == "BlobNotFound"
      raise ArtifactStore::Missing, "Artifact object does not exist: #{name}"
    end
    if already_exists && status == 412
      raise ArtifactStore::AlreadyExists, "Artifact object already exists: #{name}"
    end

    if status == 408 || status == 429 || status >= 500
      raise ArtifactStore::TemporaryError, "Azure Blob Storage returned HTTP #{status}"
    end
    details = code ? " (#{code})" : ""
    raise ArtifactStore::InvalidObject, "Azure Blob Storage returned HTTP #{status}#{details}"
  end

  # Returns Azure's error code from its header or XML, without the message.
  def azure_error_code(response)
    return response["x-ms-error-code"] if response["x-ms-error-code"].present?
    return if response.body.blank?

    document = REXML::Document.new(response.body)
    REXML::XPath.first(document, "/Error/Code")&.text
  rescue REXML::ParseException
    nil
  end
end
