# Parses an operator-controlled list of exact DNS destinations.
module AnalyticsOutboundHosts
  HOSTNAME = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/
  INTERNAL_SUFFIXES = %w[localhost local internal invalid test onion].freeze

  # DNS names are ASCII and fully qualified so IP literals and local aliases do not pass.
  def self.valid_hostname?(host)
    return false if !host.is_a?(String) || host.bytesize > 253 || !host.match?(HOSTNAME)

    suffix = host.split(".").last
    suffix.match?(/\A[a-z]{2,63}\z/) && !INTERNAL_SUFFIXES.include?(suffix)
  end

  # Invalid operator policy fails startup instead of opening egress accidentally.
  def self.parse(value)
    return nil if value.nil?

    hosts = value.split(",", -1).map(&:strip)
    if hosts.empty? || hosts.any? { !valid_hostname?(_1) || _1 != _1.downcase } ||
        hosts.uniq.size != hosts.size
      raise ArgumentError, "REPLICA_ANALYTICS_OUTBOUND_HOSTS must contain distinct lowercase DNS names"
    end

    hosts.freeze
  end
end
