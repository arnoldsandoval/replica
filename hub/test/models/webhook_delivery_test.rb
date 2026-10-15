require "test_helper"

class WebhookDeliveryTest < ActiveSupport::TestCase
  test "enforces unique GitHub delivery IDs in the database" do
    delivery = webhook_deliveries.create
    attributes = webhook_deliveries.attributes_for.merge \
      github_delivery_id: delivery.github_delivery_id

    assert_raises(ActiveRecord::RecordNotUnique) do
      WebhookDelivery.insert_all!([ attributes ])
    end
  end

  test "does not allow authenticated delivery identity to change" do
    delivery = webhook_deliveries.create

    assert_not delivery.update(event: "installation")
    assert_includes delivery.errors[:event], "cannot change"
  end

  test "allows only one request to start processing" do
    delivery = webhook_deliveries.create

    assert delivery.start_processing!
    assert_not delivery.start_processing!

    delivery.allow_retry!
    assert delivery.start_processing!
  end
end
