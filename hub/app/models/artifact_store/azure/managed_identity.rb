require "json"
require "net/http"

# Gets short-lived Azure Storage tokens for Hub's managed identity.
class ArtifactStore::Azure::ManagedIdentity
  CONTAINER_APPS_API_VERSION = "2019-08-01"
  VM_API_VERSION = "2018-02-01"

  # Azure IMDS uses this fixed, link-local address for every virtual machine:
  # https://learn.microsoft.com/azure/virtual-machines/instance-metadata-service
  VM_ENDPOINT = "http://169.254.169.254/metadata/identity/oauth2/token"

  RESOURCE = "https://storage.azure.com/"
  REFRESH_WINDOW = 5.minutes

  # Uses the hosting platform's identity endpoint without storing Azure credentials.
  def initialize(
    endpoint: ENV["IDENTITY_ENDPOINT"],
    identity_header: ENV["IDENTITY_HEADER"],
    vm_endpoint: VM_ENDPOINT,
    client_id: Rails.configuration.x.azure_managed_identity_client_id
  )
    @container_apps = endpoint.present? || identity_header.present?
    @endpoint = container_apps? ? endpoint : vm_endpoint
    @identity_header = identity_header
    @client_id = client_id
    @lock = Mutex.new
  end

  # Returns a cached token or requests a new one within five minutes of expiry.
  def token
    lock.synchronize do
      return @token if @token && @expires_at > REFRESH_WINDOW.from_now

      response = request_token
      token = response.fetch("access_token")
      expires_at = expiration(response.fetch("expires_on"))
      if token.blank? || expires_at.nil? || expires_at <= Time.current
        raise ArtifactStore::InvalidObject, "Azure managed identity returned an expired or empty token"
      end
      @token = token
      @expires_at = expires_at
      @token
    end
  rescue KeyError, JSON::ParserError, TypeError, ArgumentError
    raise ArtifactStore::InvalidObject, "Azure managed identity returned incomplete token data"
  rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
    raise ArtifactStore::TemporaryError, "Azure managed identity request failed: #{error.message}"
  end

  private

  attr_reader :client_id, :endpoint, :identity_header, :lock

  # Requests token details from the host and returns Azure's JSON response.
  def request_token
    if container_apps? && (endpoint.blank? || identity_header.blank?)
      raise ArtifactStore::InvalidObject, "Azure managed identity requires IDENTITY_ENDPOINT and IDENTITY_HEADER"
    end
    raise ArtifactStore::InvalidObject, "Azure managed identity endpoint is unavailable" if endpoint.blank?

    uri = URI.parse(endpoint)
    valid = [ URI::HTTP, URI::HTTPS ].any? { uri.is_a?(_1) } && uri.host.present? && uri.userinfo.nil?
    raise ArtifactStore::InvalidObject, "Azure managed identity endpoint must be an HTTP URL with a host" if !valid

    query = URI.decode_www_form(uri.query.to_s)
    query.concat([ [ "resource", RESOURCE ], [ "api-version", api_version ] ])
    query << [ "client_id", client_id ] if client_id.present?
    uri.query = URI.encode_www_form(query)
    request = Net::HTTP::Get.new(uri)
    if container_apps?
      request["X-IDENTITY-HEADER"] = identity_header
    else
      request["Metadata"] = "true"
    end
    response = perform(request, uri)
    if response.code.to_i == 408 || response.code.to_i == 429 || response.code.to_i >= 500
      raise ArtifactStore::TemporaryError, "Azure managed identity returned HTTP #{response.code}"
    end
    if !response.is_a?(Net::HTTPSuccess)
      raise ArtifactStore::InvalidObject, "Azure managed identity returned HTTP #{response.code}"
    end

    JSON.parse(response.body)
  rescue URI::InvalidURIError
    raise ArtifactStore::InvalidObject, "Azure managed identity endpoint must be an HTTP URL with a host"
  end

  # Selects the token API version used by the current Azure host.
  def api_version
    container_apps? ? CONTAINER_APPS_API_VERSION : VM_API_VERSION
  end

  # Reports whether Container Apps supplied its managed identity settings.
  def container_apps?
    @container_apps
  end

  # Sends the identity request without a proxy and returns Azure's response.
  def perform(request, uri)
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 5
    http.read_timeout = 10
    http.start { _1.request(request) }
  end

  # Returns a time from Azure's epoch-seconds or date-string expiration value.
  def expiration(value)
    value.to_s.match?(/\A\d+\z/) ? Time.zone.at(value.to_i) : Time.zone.parse(value.to_s)
  end
end
