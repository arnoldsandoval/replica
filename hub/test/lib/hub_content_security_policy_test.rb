require "test_helper"

class HubContentSecurityPolicyTest < ActiveSupport::TestCase
  setup do
    @previous_origins = %i[
      hub_origin github_url preview_origin_template share_preview_origin_template welcome_video_url
    ].index_with { Rails.configuration.x.public_send(_1) }
    Rails.configuration.x.hub_origin = "https://replica.example.test"
    Rails.configuration.x.github_url = "https://github.enterprise.test/"
    Rails.configuration.x.preview_origin_template = "https://b{build_id}.preview.replica.example.test"
    Rails.configuration.x.share_preview_origin_template = "https://s{build_id}.shared.replica.example.test"
    Rails.configuration.x.welcome_video_url = nil
  end

  teardown do
    @previous_origins.each { |name, value| Rails.configuration.x.public_send("#{name}=", value) }
  end

  test "production permits configured transports and forms but no arbitrary scripts" do
    header = HubContentSecurityPolicy.build(development: false).build(Object.new, "test-nonce", %w[script-src])

    assert_equal \
      "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; " \
        "script-src 'self' 'nonce-test-nonce'; script-src-attr 'none'; " \
        "style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' https: data:; " \
        "media-src 'self' 'self'; connect-src 'self' wss://replica.example.test; " \
        "frame-src 'self' https://*.preview.replica.example.test https://*.shared.replica.example.test 'self'; " \
        "form-action 'self' https://github.enterprise.test; worker-src 'none'",
      header
  end

  test "permits only YouTube's privacy-enhanced host for an embedded welcome video" do
    Rails.configuration.x.welcome_video_url = "https://www.youtube.com/watch?v=J2Z28CwIfsA"
    header = HubContentSecurityPolicy.build(development: false).build(Object.new)

    assert_includes header,
      "frame-src 'self' https://*.preview.replica.example.test " \
        "https://*.shared.replica.example.test https://www.youtube-nocookie.com"
    assert_includes header, "media-src 'self' 'self';"
    assert_not_includes header, "frame-src https:;"
  end

  test "permits only the configured video origin for external media" do
    Rails.configuration.x.welcome_video_url = "https://media.example.test:8443/intro.mp4?version=2"
    header = HubContentSecurityPolicy.build(development: false).build(Object.new)

    assert_includes header, "media-src 'self' https://media.example.test:8443"
    assert_not_includes header, "media-src 'self' https:;"
    assert_not_includes header, "/intro.mp4"
  end

  test "only development permits the configured Vite port and HMR transport" do
    Rails.configuration.x.hub_origin = "http://replica.localhost:19500"

    port = ViteRuby.config.port
    vite_origin = ViteRuby.config.origin
    development = HubContentSecurityPolicy.build(development: true).build(Object.new, "test-nonce", %w[script-src])
    production = HubContentSecurityPolicy.build(development: false).build(Object.new, "test-nonce", %w[script-src])

    assert_includes development,
      "script-src 'self' http://replica.localhost:#{port} #{vite_origin} 'nonce-test-nonce'"
    assert_includes development,
      "connect-src 'self' ws://replica.localhost:19500 http://replica.localhost:#{port} " \
        "#{vite_origin} ws://replica.localhost:#{port} #{vite_origin.sub(/\Ahttp/, 'ws')}"
    assert_includes development, "style-src 'self' 'unsafe-inline' http://replica.localhost:#{port} #{vite_origin}"
    assert_includes development, "font-src 'self' http://replica.localhost:#{port} #{vite_origin}"
    assert_includes development, "img-src 'self' https: data: http://replica.localhost:#{port} #{vite_origin}"
    assert_not_includes production, ":#{port}"
    assert_not_includes development, "'unsafe-eval'"
    refute_match(/script-src[^;]*'unsafe-inline'/, development)
  end
end
