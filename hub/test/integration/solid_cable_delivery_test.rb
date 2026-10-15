require "test_helper"
require "tmpdir"

# Exercises production broadcasts without opening the production cable database.
class SolidCableDeliveryTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # Fresh databases allow committed writes without changing the suite's test pools.
  def before_setup
    @original_server = ActionCable.method(:server)
    @original_handler = ActiveRecord::Base.connection_handler
    @original_default_handler = ActiveRecord::Base.default_connection_handler
    @original_cable_connection_name = SolidCable::Record.connection_specification_name
    @handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
    ActiveRecord::Base.default_connection_handler = @handler
    ActiveRecord::Base.connection_handler = @handler
    @directory = Dir.mktmpdir("replica-solid-cable-")
    @servers = []
    @error_reporters = []
    production = Rails.application.config_for(:cable, env: :production).to_h
    SolidCable.configure(**production.except(:connects_to))
    cable_database = database_configuration("cable")
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Base.establish_connection(cable_database)
      load Rails.root.join("db/cable_schema.rb")
      SolidCable::Record.establish_connection(cable_database)
      ActiveRecord::Base.establish_connection(database_configuration("primary"))
      load Rails.root.join("db/schema.rb")
    end
    @server = create_cable_server(production)
    server = @server
    ActionCable.define_singleton_method(:server) { server }
    super
  end

  # Finish Rails teardown before removing the databases used by its connections.
  def after_teardown
    super
  ensure
    begin
      @servers&.reverse_each do |server|
        begin
          server.restart
        ensure
          loop = server.event_loop
          loop.stop
          thread = loop.instance_variable_get(:@thread)
          assert thread.join(5), "Cable event loop did not stop" if thread
          executor = loop.instance_variable_get(:@executor)
          executor&.shutdown
          assert executor.wait_for_termination(5) if executor
        end
      end
    ensure
      begin
        @error_reporters&.each { |reporter| Rails.error.unsubscribe(reporter) }
        @handler&.clear_all_connections!(:all)
      ensure
        ActionCable.define_singleton_method(:server, @original_server)
        ActiveRecord::Base.default_connection_handler = @original_default_handler
        ActiveRecord::Base.connection_handler = @original_handler
        SolidCable::Record.connection_specification_name = @original_cable_connection_name
        SolidCable.reset_configuration!
        FileUtils.remove_entry(@directory) if @directory
      end
    end
  end

  test "delivers a persisted review invalidation to another cable server" do
    prototype = prototypes.create
    stream = ReviewCommentsChannel.broadcasting_for(prototype)
    messages = subscribe_to_cable(stream)

    ReviewCommentsChannel.broadcast_invalidation(prototype)

    expected = { "type" => "review_comments_changed" }
    assert_equal expected, messages.pop(timeout: 5)
    persisted = SolidCable::Message.find_by!(channel: stream)
    assert_equal expected, ActiveSupport::JSON.decode(persisted.payload)
    assert SolidCable.autotrim?
    assert_not SolidCable.encrypt?
  end

  test "another connection sees committed revocation before the disconnect is queued" do
    user = users.create
    secret = "rp_#{SecureRandom.urlsafe_base64(32)}"
    grant = CanvasGrant.create! \
      user:,
      repository: repositories.create,
      token_digest: Digest::SHA256.hexdigest(secret),
      expires_at: 7.days.from_now
    connection = ActiveRecord::Base.connection
    before = grant_state_from_another_connection(grant.id, secret)
    assert_nil before.fetch(:revoked_at)
    assert_equal grant.id, before.fetch(:authenticated_id)
    assert_not_equal connection.object_id, before.fetch(:connection_id)
    remote = @server.remote_connections.where(current_user: user, credential_identity: grant.to_gid_param)
    stream = "action_cable/#{remote.connection_identifier}"
    messages = subscribe_to_cable(stream)
    queued_states = []
    broadcast = @server.pubsub.method(:broadcast)
    observe = -> { queued_states << grant_state_from_another_connection(grant.id, secret) }
    @server.pubsub.define_singleton_method(:broadcast) do |channel, payload|
      observe.call if channel == stream
      broadcast.call(channel, payload)
    end

    grant.revoke!

    assert_equal 1, queued_states.size
    at_enqueue = queued_states.first
    assert at_enqueue.fetch(:revoked_at), "Revocation must be committed before queuing the disconnect"
    assert_nil at_enqueue.fetch(:authenticated_id)
    assert_not_equal connection.object_id, at_enqueue.fetch(:connection_id)
    expected = { "type" => "disconnect", "reconnect" => true }
    assert_equal expected, messages.pop(timeout: 5)
    persisted = SolidCable::Message.find_by!(channel: stream)
    assert_equal expected, ActiveSupport::JSON.decode(persisted.payload)
  end

  test "shutdown persists a queued review invalidation" do
    prototype = prototypes.create
    stream = ReviewCommentsChannel.broadcasting_for(prototype)
    SolidCable.configuration.writer_batch_delay = 5.seconds

    ReviewCommentsChannel.broadcast_invalidation(prototype)
    assert_empty SolidCable::Message.where(channel: stream)
    @server.restart

    persisted = SolidCable::Message.find_by!(channel: stream)
    expected = { "type" => "review_comments_changed" }
    assert_equal expected, ActiveSupport::JSON.decode(persisted.payload)
  end

  test "reports an asynchronous database write failure through Rails" do
    prototype = prototypes.create
    SolidCable::Record.connection_pool.with_connection do |connection|
      connection.execute <<~SQL
        CREATE TRIGGER fail_cable_write BEFORE INSERT ON solid_cable_messages
        BEGIN SELECT RAISE(FAIL, 'Cable write failure'); END
      SQL
    end
    errors = capture_cable_errors

    ReviewCommentsChannel.broadcast_invalidation(prototype)

    assert_kind_of ActiveRecord::StatementInvalid, errors.pop(timeout: 5)
  end

  private

  def database_configuration(name)
    ActiveRecord::DatabaseConfigurations::HashConfig.new \
      "test",
      name,
      { adapter: "sqlite3", database: File.join(@directory, "#{name}.sqlite3"), timeout: 5000 }
  end

  def create_cable_server(cable = @server.config.cable)
    configuration = ActionCable::Server::Configuration.new
    configuration.cable = cable.deep_stringify_keys
    configuration.logger = Rails.logger
    configuration.connection_class = -> { ApplicationCable::Connection }
    ActionCable::Server::Base.new(config: configuration).tap { |server| @servers << server }
  end

  def subscribe_to_cable(stream)
    messages = Queue.new
    ready = Queue.new
    subscriber = ->(payload) { messages << ActiveSupport::JSON.decode(payload) }
    create_cable_server.pubsub.subscribe(stream, subscriber, -> { ready << true })
    assert ready.pop(timeout: 5), "Solid Cable did not subscribe"
    messages
  end

  # A separate connection cannot see the revoking transaction before it commits.
  def grant_state_from_another_connection(id, secret)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        {
          connection_id: connection.object_id,
          revoked_at: CanvasGrant.find(id).revoked_at,
          authenticated_id: CanvasGrant.authenticate(secret)&.id
        }
      end
    end.value
  end

  def capture_cable_errors
    errors = Queue.new
    reporter = Object.new
    reporter.define_singleton_method(:report) { |error, **| errors << error }
    @error_reporters << reporter
    Rails.error.subscribe(reporter)
    errors
  end
end
