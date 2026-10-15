require "test_helper"

class ShareLinkLifetimeTest < ActiveSupport::TestCase
  test "requires a seven day maximum when the setting is absent" do
    assert_equal 7.days, ShareLinkLifetime.parse(nil)
  end

  test "accepts the supported maximum lifetimes" do
    %w[1 7 30].each do |value|
      assert_equal value.to_i.days, ShareLinkLifetime.parse(value)
    end
  end

  test "rejects empty malformed and unsupported deployment settings" do
    [ "", "0", "-7", "7days", "7.0", " 7", "07", "8", "never" ].each do |value|
      error = assert_raises(ArgumentError) { ShareLinkLifetime.parse(value) }
      assert_includes error.message, "REPLICA_SHARE_LINK_MAX_DAYS"
    end
  end
end
