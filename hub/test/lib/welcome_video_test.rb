require "test_helper"

class WelcomeVideoTest < ActiveSupport::TestCase
  setup do
    @previous_url = Rails.configuration.x.welcome_video_url
    @previous_poster_url = Rails.configuration.x.welcome_video_poster_url
  end

  teardown do
    Rails.configuration.x.welcome_video_url = @previous_url
    Rails.configuration.x.welcome_video_poster_url = @previous_poster_url
  end

  test "leaves an unconfigured video explicitly unavailable" do
    Rails.configuration.x.welcome_video_url = nil

    assert_nil WelcomeVideo.url
    assert_equal "'self'", WelcomeVideo.origin
  end

  test "keeps a hosted URL intact while restricting the policy to its origin" do
    url = "https://media.example.test/intro.mp4?version=2"
    Rails.configuration.x.welcome_video_url = url

    assert_equal url, WelcomeVideo.url
    assert_equal "https://media.example.test", WelcomeVideo.origin
  end

  test "converts a YouTube watch URL to a privacy-enhanced embed" do
    Rails.configuration.x.welcome_video_url = "https://www.youtube.com/watch?v=J2Z28CwIfsA"

    assert_nil WelcomeVideo.url
    assert_equal "https://www.youtube-nocookie.com/embed/J2Z28CwIfsA", WelcomeVideo.embed_url
    assert_equal "'self'", WelcomeVideo.origin
    assert_equal "https://www.youtube-nocookie.com", WelcomeVideo.frame_origin
  end

  test "accepts case-insensitive and mobile YouTube watch hosts" do
    [
      "https://WWW.YouTube.com/watch?v=J2Z28CwIfsA",
      "https://m.youtube.com/watch?v=J2Z28CwIfsA"
    ].each do |url|
      Rails.configuration.x.welcome_video_url = url
      assert_equal "https://www.youtube-nocookie.com/embed/J2Z28CwIfsA", WelcomeVideo.embed_url
    end
  end

  test "rejects insecure URLs, credentials, and malformed input" do
    [
      "http://media.example.test/intro.mp4", "//media.example.test/intro.mp4",
      "/intro.mp4", "https://user:password@media.example.test/intro.mp4",
      "not a URL", "javascript:alert(1)"
    ].each do |url|
      Rails.configuration.x.welcome_video_url = url
      assert_raises(ArgumentError) { WelcomeVideo.url }
    end
  end

  test "rejects malformed YouTube links and video IDs" do
    [
      "https://www.youtube.com/watch?v=invalid",
      "https://www.youtube.com/playlist?list=J2Z28CwIfsA",
      "https://www.youtube.com:444/watch?v=J2Z28CwIfsA",
      "https://user@www.youtube.com/watch?v=J2Z28CwIfsA"
    ].each do |url|
      Rails.configuration.x.welcome_video_url = url
      assert_raises(ArgumentError) { WelcomeVideo.embed_url }
    end
  end

  test "accepts an optional HTTPS poster and rejects unsafe poster URLs" do
      Rails.configuration.x.welcome_video_poster_url = nil
      assert_nil WelcomeVideo.poster_url

      Rails.configuration.x.welcome_video_poster_url = "https://media.example.test/poster.jpg"
      assert_equal "https://media.example.test/poster.jpg", WelcomeVideo.poster_url

      [ "http://media.example.test/poster.jpg", "//media.example.test/poster.jpg",
        "/poster.jpg", "https://user:password@media.example.test/poster.jpg", "not a URL" ].each do |value|
        Rails.configuration.x.welcome_video_poster_url = value
        assert_raises(ArgumentError) { WelcomeVideo.poster_url }
    end
  end
end
