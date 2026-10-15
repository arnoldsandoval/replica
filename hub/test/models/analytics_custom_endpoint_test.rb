require "test_helper"

class AnalyticsCustomEndpointTest < ActiveSupport::TestCase
  test "allows bounded public HTTPS query settings without revealing a query in errors" do
    endpoint = Analytics::CustomEndpoint.new("https://events.example.com/collect?version=1&monkey=eu")
    assert_equal "events.example.com", endpoint.uri.host
    assert_equal "/collect?version=1&monkey=eu", endpoint.uri.request_uri

    [
      "http://events.example.com/collect",
      "https://events.example.com:8443/collect",
      "https://127.0.0.1/collect",
      "https://user:pass@events.example.com/collect",
      "https://events.example.com/collect#fragment",
      "https://events.example.com/collect?api_key=private",
      "https://events.example.com/collect?api%5Fkey=private",
      "https://events.example.com/collect?mode=%24secret",
      "https://events.example.com/collect?mode=%00",
      "https://events.example.com/collect?version=#{'x' * 129}",
      "https://events.example.com/collect?#{(1..11).map { "v#{_1}=1" }.join('&')}",
      "https://replica.localhost/collect",
      "https://b123.preview.replica.localhost/collect",
      "https://metadata.google.internal/collect"
    ].each do |url|
      error = assert_raises(Analytics::CustomEndpoint::Invalid) do
        Analytics::CustomEndpoint.new(url)
      end
      assert_not_includes error.message, "private"
      assert_not_includes error.message, "collect?"
    end
  end

  test "rejects mixed DNS public and restricted answers as well as special address space" do
    [
      "127.0.0.1", "10.0.0.1", "169.254.169.254", "100.64.0.1", "192.168.1.2",
      "172.17.0.1", "198.19.0.1", "0.1.2.3", "203.0.113.1", "::1", "fe80::1",
      "fc00::1", "::ffff:127.0.0.1", "2001:db8::1", "2002::1"
    ].each do |ip|
      assert_not Analytics::CustomEndpoint.public_ip?(ip), ip
    end
    assert Analytics::CustomEndpoint.public_ip?("8.8.8.8")
    assert Analytics::CustomEndpoint.public_ip?("2001:4860:4860::8888")
    answers = [ Addrinfo.tcp("8.8.8.8", 443), Addrinfo.tcp("169.254.169.254", 443) ]
    endpoint = Analytics::CustomEndpoint.new \
      "https://events.example.com/collect", resolver: ->(_) { answers }
    assert_raises(Analytics::CustomEndpoint::Invalid) { endpoint.public_ip! }
  end

  test "pins the public socket IP while keeping the original TLS hostname and disabling proxies" do
    previous_proxy = ENV["HTTPS_PROXY"]
    answers = [ Addrinfo.tcp("8.8.8.8", 443) ]
    endpoint = Analytics::CustomEndpoint.new \
      "https://events.example.com/collect", resolver: ->(_) { answers }
    ip = endpoint.public_ip!
    ENV["HTTPS_PROXY"] = "http://127.0.0.1:8080"
    http = endpoint.http(ip)
    assert_equal "8.8.8.8", http.ipaddr
    assert_equal "events.example.com", http.address
    assert http.use_ssl?
    assert http.verify_hostname
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_not http.proxy?
    assert_equal 0, http.max_retries
  ensure
    ENV["HTTPS_PROXY"] = previous_proxy
  end

  test "optional exact-domain allowlist rejects other public hosts" do
    original = Rails.configuration.x.analytics_outbound_hosts
    Rails.configuration.x.analytics_outbound_hosts = [ "events.example.com" ]
    assert_nothing_raised { Analytics::CustomEndpoint.new("https://events.example.com/collect") }
    assert_raises(Analytics::CustomEndpoint::Invalid) do
      Analytics::CustomEndpoint.new("https://other.example.com/collect")
    end
    assert_raises(ArgumentError) { AnalyticsOutboundHosts.parse("events.example.com,") }
    assert_raises(ArgumentError) { AnalyticsOutboundHosts.parse("EXAMPLE.com") }
  ensure
    Rails.configuration.x.analytics_outbound_hosts = original
  end
end
