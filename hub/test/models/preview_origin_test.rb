require "test_helper"

class PreviewOriginTest < ActiveSupport::TestCase
  test "builds and recognizes one Build origin" do
    origin = PreviewOrigin.new("http://b{build_id}.preview.replica.localhost:19500")
    request = ActionDispatch::TestRequest.create
    request.set_header("HTTP_HOST", "b42.preview.replica.localhost:19500")
    request.set_header("rack.url_scheme", "http")

    assert_equal "http://b42.preview.replica.localhost:19500/settings", origin.url(42, path: "/settings")
    assert_equal 42, origin.build_id(request)
  end

  test "rejects a malformed template" do
    invalid_templates = [
      "https://preview.example.com",
      "https://b{build_id}.{build_id}.example.com",
      "https://user@b{build_id}.example.com",
      "https://b{build_id}.example.com/path"
    ]

    invalid_templates.each do |template|
      assert_raises(ArgumentError) { PreviewOrigin.new(template) }
    end
  end

  test "recognizes any matching Build host without a scheme check" do
    origin = PreviewOrigin.new("https://8123456789-b{build_id}.example.test")

    assert_equal 27, origin.build_id("8123456789-b27.example.test")
  end

  test "recognizes when the Hub host falls inside the preview namespace" do
    origin = PreviewOrigin.new("https://b{build_id}.preview.example.test")

    assert_equal 2, origin.build_id("b2.preview.example.test")
  end

  test "requires the preview to share the Hub scheme and parent host" do
    origin = PreviewOrigin.new("https://b{build_id}.preview.replica.example.com")

    assert origin.same_site_with?("https://replica.example.com")
    assert_not origin.same_site_with?("http://replica.example.com")
    assert_not origin.same_site_with?("https://replica.example.net")
  end

  test "normalizes DNS host case and a trailing dot" do
    origin = PreviewOrigin.new("https://b{build_id}.preview.example.test")

    assert_equal 2, origin.build_id("B2.PREVIEW.EXAMPLE.TEST.")
  end

  test "avoids a case-insensitive marker collision" do
    origin = PreviewOrigin.new("https://REPLICABUILDID-b{build_id}.example.test")

    assert_equal 2, origin.build_id("replicabuildid-b2.example.test")
  end

  test "builds the configured public share preview origin" do
    origin = SharePreviewOrigin.current

    assert_equal "s42.preview.replica.localhost", origin.host_for(42)
    assert_equal 42, origin.build_id("s42.preview.replica.localhost")
  end

  test "scopes frame sources to the configured parent domain and port" do
    assert_equal "http://*.preview.replica.localhost:19500",
      PreviewOrigin.current.frame_source
    assert_equal "http://*.preview.replica.localhost:19500",
      SharePreviewOrigin.current.frame_source
    assert_equal "https://*.preview.example.test",
      PreviewOrigin.new("https://nested.build-{build_id}.preview.example.test/").frame_source
    assert_equal "https://*.shared.example.test:8443",
      SharePreviewOrigin.new("https://s{build_id}.shared.example.test:8443").frame_source
  end

  test "refuses a frame source without a fixed parent domain" do
    assert_raises(ArgumentError) { PreviewOrigin.new("http://b{build_id}").frame_source }
  end
end
