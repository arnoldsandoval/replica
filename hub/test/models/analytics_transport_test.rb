require "test_helper"

class AnalyticsTransportTest < ActiveSupport::TestCase
  setup do
    @repository = repositories.create
    prototype = prototypes.create(repository: @repository)
    prototype.register!(name: "Welcome", author: users.create)
    @event = Analytics::Event.sole
  end

  test "uses the fixed Segment endpoint in each region" do
    { "us" => "api.segment.io", "eu" => "events.eu1.segmentapis.com" }.each do |region, host|
      destination = configured("segment", region, { "write_key" => "private-key" })
      request = stub_request(:post, "https://#{host}/v1/track")
        .with(basic_auth: [ "private-key", "" ])
        .to_return(status: 200, body: '{"success":true}')
      Analytics::Transport.new(destination).deliver(@event)
      assert_requested request
    end
  end

  test "uses strict single-event Mixpanel imports in each region" do
    { "us" => "api.mixpanel.com", "eu" => "api-eu.mixpanel.com", "in" => "api-in.mixpanel.com" }.each do |region, host|
      destination = configured \
        "mixpanel", region,
        { "service_account_username" => "service-user", "service_account_secret" => "private-secret", "project_id" => "123" }
      request = stub_request(:post, "https://#{host}/import?strict=1&project_id=123")
        .with(basic_auth: [ "service-user", "private-secret" ]) do |request|
          batch = JSON.parse(request.body)
          properties = batch.sole["properties"]
          batch.sole["event"] == @event.name && properties["$insert_id"] == @event.uuid &&
            properties["distinct_id"] == @event.actor_id && properties["time"] == @event.occurred_at.to_i &&
            properties["actor_type"] == "person" && properties["ip"] == 0
        end.to_return(status: 200, body: '{"status":"OK","num_records_imported":1}')
      Analytics::Transport.new(destination).deliver(@event)
      assert_requested request
    end
  end

  test "rejects redirects oversized malformed and unsuccessful responses" do
    destination = configured("segment", "us", { "write_key" => "private-key" })
    [
      [ 302, "", "http_302" ], [ 401, "Secret provider detail", "http_401" ],
      [ 200, "x" * 16_385, "response_too_large" ], [ 200, "not json", "invalid_response" ],
      [ 200, "null", "invalid_response" ], [ 200, '{"success":false}', "provider_rejected" ]
    ].each do |status, body, code|
      stub_request(:post, "https://api.segment.io/v1/track")
        .to_return(status:, body:, headers: { "Location" => "https://example.com/collect" })
      error = assert_raises(Analytics::Transport::Failure) { Analytics::Transport.new(destination).deliver(@event) }
      assert_equal code, error.code
      assert_not error.retryable
    end
    assert_not_requested :post, "https://example.com/collect"
  end

  test "requires Mixpanel to confirm exactly one imported event" do
    destination = configured \
      "mixpanel", "us",
      { "service_account_username" => "service-user", "service_account_secret" => "private-secret", "project_id" => "123" }
    [ '{"status":"OK","num_records_imported":0}', '{"status":"Bad Request","num_records_imported":1}' ].each do |body|
      stub_request(:post, "https://api.mixpanel.com/import?strict=1&project_id=123")
        .to_return(status: 200, body:)
      error = assert_raises(Analytics::Transport::Failure) { Analytics::Transport.new(destination).deliver(@event) }
      assert_equal "provider_rejected", error.code
    end
  end

  test "unknown actors get event-specific system identities on both providers" do
    prototype = prototypes.create(repository: @repository, branch_name: "prototype/system")
    prototype.register!(name: "System registration", author: nil)
    event = Analytics::Event.find_by!(source_key: "prototype/#{prototype.id}/registered")
    segment = configured("segment", "us", { "write_key" => "private-key" })
    segment_request = stub_request(:post, "https://api.segment.io/v1/track")
      .with { JSON.parse(_1.body)["anonymousId"] == "system/#{event.uuid}" }
      .to_return(status: 200, body: '{"success":true}')
    Analytics::Transport.new(segment).deliver(event)
    assert_requested segment_request

    mixpanel = configured \
      "mixpanel", "us",
      { "service_account_username" => "service-user", "service_account_secret" => "private-secret", "project_id" => "123" }
    mixpanel_request = stub_request(:post, "https://api.mixpanel.com/import?strict=1&project_id=123")
      .with do |request|
        properties = JSON.parse(request.body).sole.fetch("properties")
        properties["distinct_id"] == "system/#{event.uuid}" &&
          properties["actor_type"] == "system" && properties["$insert_id"] == event.uuid &&
          properties["ip"] == 0
      end.to_return(status: 200, body: '{"status":"OK","num_records_imported":1}')
    2.times { Analytics::Transport.new(mixpanel).deliver(event) }
    assert_requested mixpanel_request, times: 2
    assert_nil event.reload.actor_id
  end

  test "retries timeouts and rate limits without retaining provider messages" do
    destination = configured("segment", "us", { "write_key" => "private-key" })
    stub_request(:post, "https://api.segment.io/v1/track").to_timeout
    error = assert_raises(Analytics::Transport::Failure) { Analytics::Transport.new(destination).deliver(@event) }
    assert_equal "network_error", error.code
    assert error.retryable
    stub_request(:post, "https://api.segment.io/v1/track").to_return(status: 429, body: "private detail")
    error = assert_raises(Analytics::Transport::Failure) { Analytics::Transport.new(destination).deliver(@event) }
    assert_equal "http_429", error.message
    assert error.retryable
  end

  private

  def configured(provider, region, credentials)
    Analytics::Destination.new(repository: @repository, provider:, region:, credentials:, event_types: Analytics::Event::TYPES)
  end
end
