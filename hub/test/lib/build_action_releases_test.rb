require "test_helper"

class BuildActionReleasesTest < ActiveSupport::TestCase
  test "rejects a blank current Action pin" do
    error = assert_raises RuntimeError do
      BuildActionReleases.parse([ "" ])
    end

    assert_equal "Invalid build Action release list", error.message
  end

  test "accepts a reviewed pin and an older release" do
    lines = [ "github/replica/actions/build@#{"a" * 40}", "b" * 40 ]

    assert_equal lines, BuildActionReleases.parse(lines)
  end
end
