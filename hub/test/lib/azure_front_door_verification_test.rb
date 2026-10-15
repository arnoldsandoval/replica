require "test_helper"

class AzureFrontDoorVerificationTest < ActiveSupport::TestCase
  FRONT_DOOR_ID = "11111111-1111-1111-1111-111111111111"

  test "allows requests from the configured Front Door" do
    application = ->(_environment) { [ 200, {}, [ "allowed" ] ] }
    middleware = AzureFrontDoorVerification.new(application, front_door_id: FRONT_DOOR_ID)
    environment = Rack::MockRequest.env_for \
      "https://replica.example.com",
      "HTTP_X_AZURE_FDID" => FRONT_DOOR_ID.upcase

    status, _, body = middleware.call(environment)

    assert_equal 200, status
    assert_equal [ "allowed" ], body
  end

  test "rejects requests from another Front Door" do
    application = ->(_environment) { [ 200, {}, [ "allowed" ] ] }
    middleware = AzureFrontDoorVerification.new(application, front_door_id: FRONT_DOOR_ID)
    environment = Rack::MockRequest.env_for \
      "https://replica.example.com",
      "HTTP_X_AZURE_FDID" => "22222222-2222-2222-2222-222222222222"

    status, _, body = middleware.call(environment)

    assert_equal 404, status
    assert_empty body
  end

  test "rejects requests without a Front Door identifier" do
    application = ->(_environment) { [ 200, {}, [ "allowed" ] ] }
    middleware = AzureFrontDoorVerification.new(application, front_door_id: FRONT_DOOR_ID)

    status, _, = middleware.call(Rack::MockRequest.env_for("https://replica.example.com"))

    assert_equal 404, status
  end

  test "allows the health check without a Front Door identifier" do
    application = ->(_environment) { [ 200, {}, [ "allowed" ] ] }
    middleware = AzureFrontDoorVerification.new(application, front_door_id: FRONT_DOOR_ID)

    status, _, body = middleware.call(Rack::MockRequest.env_for("http://replica.example.com/up"))

    assert_equal 200, status
    assert_equal [ "allowed" ], body
  end

  test "does not restrict deployments without a configured Front Door" do
    application = ->(_environment) { [ 200, {}, [ "allowed" ] ] }
    middleware = AzureFrontDoorVerification.new(application, front_door_id: nil)

    status, _, = middleware.call(Rack::MockRequest.env_for("https://replica.example.com"))

    assert_equal 200, status
  end
end
