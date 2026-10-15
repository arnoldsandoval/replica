# Parses the deployment maximum, defaulting to seven days.
module ShareLinkLifetime
  # Invalid policy prevents startup instead of silently allowing longer links.
  def self.parse(value)
    return 7.days if value.nil?

    unless %w[1 7 30].include?(value)
      raise ArgumentError, "REPLICA_SHARE_LINK_MAX_DAYS must be 1, 7, or 30"
    end

    value.to_i.days
  end
end
