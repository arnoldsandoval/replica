require "test_helper"

class Build::LocalPackageTest < ActiveSupport::TestCase
  MISSING = "/nonexistent/chromium"

  test "screenshots prefer a configured Chromium, then the image's own" do
    assert_equal chromium("/opt/chrome/chrome"), browser_environment(chromium("/opt/chrome/chrome"), system_chromium: RbConfig.ruby)
    assert_equal chromium(RbConfig.ruby), browser_environment({}, system_chromium: RbConfig.ruby)
  end

  test "without a Chromium, screenshots use Playwright's browsers from the real home" do
    assert_equal browsers("/Users/ana/Library/Caches/ms-playwright"), browser_environment({}, home: "/Users/ana", macos: true)
    assert_equal browsers("/home/ana/.cache/ms-playwright"), browser_environment({}, macos: false)
    assert_equal browsers("/srv/browsers"), browser_environment(browsers("/srv/browsers"))
  end

  test "relative browser paths count from the build action, where Chromium is installed" do
    action = "/srv/replica/actions/build"

    assert_equal browsers("#{action}/.playwright"), browser_environment(browsers(".playwright"), action:)
    assert_equal browsers("0"), browser_environment(browsers("0"), action:)
    assert_equal chromium("#{action}/chrome/chrome"), browser_environment(chromium("chrome/chrome"), action:)
  end

  test "a relative XDG cache directory is ignored, as the XDG specification requires" do
    assert_equal browsers("/home/ana/.cache/ms-playwright"), browser_environment({ "XDG_CACHE_HOME" => "cache" }, macos: false)
    assert_equal browsers("/var/cache/ana/ms-playwright"), browser_environment({ "XDG_CACHE_HOME" => "/var/cache/ana" }, macos: false)
  end

  private

  # The screenshot environment for a person whose home is /home/ana, with no Chromium in the image
  # unless the test names one.
  def browser_environment(env, home: "/home/ana", system_chromium: MISSING, **options)
    Build::LocalPackage.browser_environment(env: { "HOME" => home, **env }, system_chromium:, **options)
  end

  def browsers(path)
    { "PLAYWRIGHT_BROWSERS_PATH" => path }
  end

  def chromium(path)
    { "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH" => path }
  end
end
