require "test_helper"

class AnalyticsCustomDeliveryTest < ActiveSupport::TestCase
  setup do
    @repository = repositories.create
    @prototype = prototypes.create(repository: @repository)
  end

  test "multiple named custom destinations retain one-per-provider builtins" do
    first = destination("Warehouse")
    second = destination("Data lake")
    assert_equal [ "Data lake", "Warehouse" ], @repository.analytics_destinations.order(:name).pluck(:name)
    assert_not_equal first.id, second.id
    assert_raises(ActiveRecord::RecordInvalid) { destination("warehouse") }
    assert_raises(ActiveRecord::RecordInvalid) { destination("Warehouse\nHidden") }
    assert_raises(ActiveRecord::RecordNotUnique) { second.update_columns(name: "warehouse") }
    assert_raises(ActiveRecord::RecordInvalid) do
      @repository.analytics_destinations.create! \
        provider: "segment", region: "us", event_types: Analytics::Event::TYPES,
        credentials: { "write_key" => "initial" }
      @repository.analytics_destinations.create! \
        provider: "segment", region: "us", event_types: Analytics::Event::TYPES,
        credentials: { "write_key" => "duplicate" }
    end
    raw = Analytics::Destination.connection.select_one \
      "SELECT custom_config, credentials FROM analytics_destinations WHERE id = #{first.id}"
    assert_not_includes raw.to_json, "Bearer private"
    assert_not_includes raw.to_json, "https://example.com/collect"
  end

  test "new-only default and explicit retained history remain repository-scoped" do
    @prototype.register!(name: "Welcome")
    event = @repository.analytics_events.sole
    new_only = destination("New only")
    assert_empty new_only.deliveries
    retained = destination("Retained", include_retained: true)
    assert_equal [ event.id ], retained.deliveries.pluck(:event_id)
  end

  test "an operator allowlist change does not prevent admins from pausing or disconnecting" do
    configured = destination
    original_hosts = Rails.configuration.x.analytics_outbound_hosts
    Rails.configuration.x.analytics_outbound_hosts = [ "other.example.com" ]
    configured.update!(enabled: false)
    assert_not configured.reload.enabled?
    configured.update!(enabled: true)
    assert configured.reload.enabled?
    configured.destroy!
    assert_not Analytics::Destination.exists?(configured.id)
  ensure
    Rails.configuration.x.analytics_outbound_hosts = original_hosts
  end

  test "changing URL or template cancels old pending work and future events use the new revision" do
    configured = destination
    @prototype.register!(name: "Welcome")
    old = configured.deliveries.sole
    changed = input
    changed["endpoint"] = "https://new.example.com/collect"
    reconfigure(configured, changed)
    assert_equal 2, configured.reload.revision
    assert_equal "canceled", old.reload.state
    assert_nil old.lease_token
    assert_nil configured.last_delivered_at
    another = prototypes.create(repository: @repository, branch_name: "prototype/new")
    another.register!(name: "Second")
    assert_equal [ 1, 2 ], configured.deliveries.order(:id).pluck(:destination_revision)
    assert_equal %w[canceled pending], configured.deliveries.order(:id).pluck(:state)
    assert_raises(Analytics::CustomConfiguration::Invalid) do
      reconfigure(configured, input, keep_pending: true)
    end
    assert_equal 2, configured.reload.revision
  end

  test "authentication-only rotation cancels by default or rebinds pending work when affirmed" do
    configured = destination
    @prototype.register!(name: "Welcome")
    old = configured.deliveries.sole
    rotated = input
    rotated["secrets"].first["value"] = "Bearer rotated"
    reconfigure(configured, rotated, keep_pending: true)
    assert_equal 2, configured.reload.revision
    assert_equal "pending", old.reload.state
    assert_equal 2, old.destination_revision
    assert_equal "Bearer rotated", configured.credentials["api_token"]

    updated = input
    updated["secrets"].first["value"] = "Bearer again"
    reconfigure(configured, updated)
    assert_equal "canceled", old.reload.state
    assert_equal 3, configured.reload.revision
  end

  test "only authentication headers qualify for retaining the pending backlog" do
    configured = destination
    @prototype.register!(name: "Welcome")
    delivery = configured.deliveries.sole
    auth_header = input
    auth_header["headers"] = '{"Authorization":"Bearer updated"}'
    reconfigure(configured, auth_header, keep_pending: true)
    assert_equal 2, delivery.reload.destination_revision
    assert_equal "pending", delivery.state

    other_header = auth_header.merge("headers" => '{"Authorization":"Bearer updated","X-Mode":"v2"}')
    assert_raises(Analytics::CustomConfiguration::Invalid) do
      reconfigure(configured, other_header, keep_pending: true)
    end
    assert_equal 2, configured.reload.revision
    reconfigure(configured, other_header)
    assert_equal "canceled", delivery.reload.state
  end

  test "routing headers containing auth or token cannot rebind old deliveries" do
    destinations = %w[X-Token-Tenant X-Author-Version].map.with_index do |header, index|
      original = input.merge("headers" =>
        { "Authorization" => { "$secret" => "api_token" }, header => "recipient-one" }.to_json)
      [ destination("Route #{index}", custom_input: original), header, original ]
    end
    @prototype.register!(name: "Welcome")

    destinations.each do |configured, header, original|
      delivery = configured.deliveries.sole
      changed = original.merge("headers" =>
        { "Authorization" => { "$secret" => "api_token" }, header => "recipient-two" }.to_json)
      changed["secrets"].first["value"] = "Bearer rotated"
      assert_raises(Analytics::CustomConfiguration::Invalid) do
        reconfigure(configured, changed, keep_pending: true)
      end
      assert_equal 1, configured.reload.revision
      assert_equal "pending", delivery.reload.state
      reconfigure(configured, changed)
      assert_equal "canceled", delivery.reload.state
    end
  end

  test "only exact authentication header names can retain pending deliveries" do
    configured = Analytics::CustomConfiguration::AUTHENTICATION_HEADERS.map.with_index do |header, index|
      original = input.merge("headers" => { header.upcase => "initial" }.to_json)
      [ destination("Auth #{index}", custom_input: original), header, original ]
    end
    @prototype.register!(name: "Welcome")

    configured.each do |destination, header, original|
      changed = original.merge("headers" => { header.upcase => "updated" }.to_json)
      delivery = destination.deliveries.sole
      reconfigure(destination, changed, keep_pending: true)
      assert_equal "pending", delivery.reload.state
      assert_equal 2, delivery.destination_revision
    end
  end

  test "changing the response rule also cancels old work" do
    configured = destination
    @prototype.register!(name: "Welcome")
    delivery = configured.deliveries.sole
    changed = input.merge("success_pointer" => "/ok", "success_value" => "true")
    reconfigure(configured, changed)
    assert_equal "canceled", delivery.reload.state
  end

  test "claimed work is not rebound and stale revisions cannot send with new credentials" do
    configured = destination
    @prototype.register!(name: "Welcome")
    delivery = configured.deliveries.sole
    delivery.update!(state: "delivering", lease_token: "old", attempts: 1, due_at: 1.second.ago)
    rotated = input
    rotated["secrets"].first["value"] = "Bearer rotated"
    reconfigure(configured, rotated, keep_pending: true)
    assert_equal "canceled", delivery.reload.state
    assert_nil delivery.lease_token
    delivery.update!(state: "pending", destination_revision: 1)
    request = stub_request(:post, "https://example.com/collect?version=1")
      .to_return(status: 200)
    delivery.deliver!
    assert_not_requested request
    assert_equal 0, delivery.reload.attempts - 1
    assert_not_includes Analytics::Delivery.due, delivery
  end

  test "sends no extra body fields and keeps a stable header over retries" do
    configured = destination
    @prototype.register!(name: "Welcome")
    event = @repository.analytics_events.sole
    endpoint = public_endpoint
    request = stub_request(:post, "https://example.com/collect?version=1")
      .with(headers: { "Authorization" => "Bearer private", "X-Replica-Event-Id" => event.uuid }) do |sent|
        payload = JSON.parse(sent.body)
        payload == { "event" => event.name, "value" => event.properties["repository_id"] }
      end.to_return(status: 202, body: "")
    2.times { Analytics::Transport.new(configured, custom_endpoint: endpoint).deliver(event) }
    assert_requested request, times: 2
  end

  test "optional JSON response check and redirects report sanitized failures" do
    configured = destination
    @prototype.register!(name: "Welcome")
    event = @repository.analytics_events.sole
    endpoint = public_endpoint
    checked = input
    checked["success_pointer"] = "/result/accepted"
    checked["success_value"] = "true"
    reconfigure(configured, checked)
    [
      [ 200, '{"result":{"accepted":true}}', nil ],
      [ 200, '{"result":{"accepted":false}}', "response_mismatch" ],
      [ 200, "private provider response", "response_mismatch" ],
      [ 302, "", "http_302" ],
      [ 503, "private provider response", "http_503" ],
      [ 200, "x" * 16_385, "response_too_large" ]
    ].each do |status, body, code|
      stub_request(:post, "https://example.com/collect?version=1")
        .to_return(status:, body:, headers: { "Location" => "https://elsewhere.example.com" })
      if code
        error = assert_raises(Analytics::Transport::Failure) do
          Analytics::Transport.new(configured, custom_endpoint: endpoint).deliver(event)
        end
        assert_equal code, error.code
        assert_not_includes error.message, "private"
        assert_equal status == 503, error.retryable
      else
        assert_nothing_raised { Analytics::Transport.new(configured, custom_endpoint: endpoint).deliver(event) }
      end
    end
    assert_not_requested :post, "https://elsewhere.example.com"
  end

  test "rechecks DNS on every attempt and rejects a private rebinding answer" do
    configured = destination
    @prototype.register!(name: "Welcome")
    event = @repository.analytics_events.sole
    answers = [
      [ Addrinfo.tcp("8.8.8.8", 443) ],
      [ Addrinfo.tcp("8.8.8.8", 443), Addrinfo.tcp("169.254.169.254", 443) ]
    ]
    endpoint = Analytics::CustomEndpoint.new \
      "https://example.com/collect?version=1", resolver: ->(_) { answers.shift }
    request = stub_request(:post, "https://example.com/collect?version=1")
      .to_return(status: 200, body: "")
    Analytics::Transport.new(configured, custom_endpoint: endpoint).deliver(event)
    error = assert_raises(Analytics::Transport::Failure) do
      Analytics::Transport.new(configured, custom_endpoint: endpoint).deliver(event)
    end
    assert_equal "unsafe_endpoint", error.code
    assert_not error.retryable
    assert_requested request, times: 1
  end

  private

  def input
    {
      "endpoint" => "https://example.com/collect?version=1",
      "headers" => '{"Authorization":{"$secret":"api_token"}}',
      "template" => '{"event":{"$field":"event_name"},"value":{"$field":"repository_id"}}',
      "success_pointer" => "", "success_value" => "",
      "secrets" => [ { "name" => "api_token", "value" => "Bearer private" } ]
    }
  end

  def destination(name = "Warehouse", include_retained: false, custom_input: input)
    configured = @repository.analytics_destinations.new
    attributes = { provider: "custom", name:, event_types: Analytics::Event::TYPES, custom_input: }
    configured.configure!(attributes, include_retained:)
    configured
  end

  def reconfigure(configured, custom_input, keep_pending: false)
    attributes = {
      provider: "custom", name: configured.name, event_types: Analytics::Event::TYPES, custom_input:
    }
    configured.configure!(attributes, keep_pending:)
  end

  def public_endpoint
    Analytics::CustomEndpoint.new \
      "https://example.com/collect?version=1",
      resolver: ->(_) { [ Addrinfo.tcp("8.8.8.8", 443) ] }
  end
end
