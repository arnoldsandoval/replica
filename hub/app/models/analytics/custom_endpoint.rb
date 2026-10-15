require "ipaddr"
require "net/http"
require "timeout"

# Connects only to public DNS answers while verifying TLS against the saved hostname.
class Analytics::CustomEndpoint
  BLOCKED_IPV4 = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24
    192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
    224.0.0.0/4 240.0.0.0/4
  ].map { IPAddr.new(_1) }.freeze
  BLOCKED_IPV6 = %w[2001::/23 2001:db8::/32 2002::/16].map { IPAddr.new(_1) }.freeze
  GLOBAL_IPV6 = IPAddr.new("2000::/3")
  SENSITIVE_QUERY_KEY =
    /(?:\A|[._-])(?:auth|pass|key)(?:\z|[._-])|authorization|authentication|oauth|token|secret|pass(?:word|wd|phrase|code)|credential|signature|bearer|(?:api|access|private|client)key/i

  class Invalid < StandardError; end
  class LookupFailure < Invalid; end

  attr_reader :uri

  # Resolves all address families before choosing an IP to pin.
  def self.resolve(host)
    Addrinfo.getaddrinfo(host, 443, nil, Socket::SOCK_STREAM)
  end

  # Checks URL shape and deployment policy before any DNS or outbound connection.
  def initialize(url, resolver: nil)
    raise Invalid, "Enter an HTTPS URL under 2048 bytes" if !url.is_a?(String) || url.bytesize > 2048

    @uri = URI.parse(url)
    @resolver = resolver || self.class.method(:resolve)
    host = @uri.host
    if @uri.scheme != "https" || @uri.port != 443 || @uri.userinfo || @uri.fragment ||
        !AnalyticsOutboundHosts.valid_hostname?(host) || host != host.downcase
      raise Invalid, "Use a public DNS name over HTTPS on port 443, without credentials or a fragment"
    end
    hub_host = URI.parse(Rails.configuration.x.hub_origin).host
    if host == hub_host || host.end_with?(".#{hub_host}") ||
        (Rails.configuration.x.analytics_outbound_hosts &&
          !Rails.configuration.x.analytics_outbound_hosts.include?(host))
      raise Invalid, "The destination hostname is not allowed"
    end

    validate_query!
  rescue URI::InvalidURIError
    raise Invalid, "Enter a valid HTTPS URL"
  end

  # Re-resolves all families on every send; one restricted answer rejects the host.
  def public_ip!
    addresses = Timeout.timeout(5) { @resolver.call(uri.host).map(&:ip_address).uniq }
    if addresses.empty? || addresses.any? { !self.class.public_ip?(_1) }
      raise Invalid, "The destination does not resolve only to public addresses"
    end

    addresses.first
  rescue SocketError, Timeout::Error
    raise LookupFailure, "The destination hostname could not be resolved"
  end

  # Explicit nil proxy bypasses HTTP_PROXY and related environment settings.
  def http(ip)
    Net::HTTP.new(uri.host, 443, nil).tap do |client|
      client.ipaddr = ip
      client.use_ssl = true
      client.verify_mode = OpenSSL::SSL::VERIFY_PEER
      client.verify_hostname = true
      client.open_timeout = 5
      client.read_timeout = 10
      client.write_timeout = 10
      client.max_retries = 0
    end
  end

  # Rejects reserved IPv4 and IPv6 space, including mapped IPv4 addresses.
  def self.public_ip?(address)
    ip = IPAddr.new(address)
    if ip.ipv4?
      BLOCKED_IPV4.none? { _1.include?(ip) }
    else
      GLOBAL_IPV6.include?(ip) && BLOCKED_IPV6.none? { _1.include?(ip) }
    end
  rescue IPAddr::InvalidAddressError
    false
  end

  private

  # Nonsecret query settings are visible to admins, never treated as credentials.
  def validate_query!
    return if uri.query.nil?

    query = uri.query
    if query.bytesize > 512 || query.match?(/%(?![0-9a-fA-F]{2})/)
      raise Invalid, "Query settings are too long or malformed"
    end

    pairs = URI.decode_www_form(query, Encoding::UTF_8)
    invalid = pairs.any? do |key, value|
      !key.match?(/\A[a-zA-Z0-9_.-]{1,64}\z/) || value.bytesize > 128 ||
        key.match?(SENSITIVE_QUERY_KEY) ||
        value.match?(/\$secret|\$\{|\{\{|\p{Cc}/)
    end
    if pairs.empty? || pairs.size > 10 || invalid
      raise Invalid, "Query settings must be short, nonsecret key/value pairs"
    end
  rescue ArgumentError
    raise Invalid, "Query settings must be valid UTF-8"
  end
end
