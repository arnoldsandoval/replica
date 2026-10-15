# Uses forwarded client addresses only behind the configured proxy boundary.
module TrustedRequestSource
  private

  def trusted_request_ip
    proxies = Rails.application.config.action_dispatch.trusted_proxies ||
      ActionDispatch::RemoteIp::TRUSTED_PROXIES
    peer = request.remote_addr
    proxies.any? { _1 === peer } ? request.remote_ip : peer
  end
end
