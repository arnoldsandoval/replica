module ShareLinkLifetimeHelpers
  def with_share_link_maximum_lifetime(maximum)
    previous = Rails.configuration.x.share_link_maximum_lifetime
    Rails.configuration.x.share_link_maximum_lifetime = maximum
    yield
  ensure
    Rails.configuration.x.share_link_maximum_lifetime = previous
  end
end
