require "test_helper"
require "tmpdir"

class PrototypeIntroductionConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  # Independent request connections need committed fixtures in a private database.
  def before_setup
    @original_handler = ActiveRecord::Base.connection_handler
    @original_default_handler = ActiveRecord::Base.default_connection_handler
    @handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
    @directory = Dir.mktmpdir("replica-prototype-introductions-")
    ActiveRecord::Base.default_connection_handler = @handler
    ActiveRecord::Base.connection_handler = @handler
    configuration = ActiveRecord::Base.configurations.configs_for(env_name: "test").first.configuration_hash
    ActiveRecord::Base.establish_connection(configuration.merge(database: File.join(@directory, "primary.sqlite3")))
    ActiveRecord::Migration.suppress_messages { load Rails.root.join("db/schema.rb") }
    super
  end

  def after_teardown
    super
  ensure
    @handler&.clear_all_connections!(:all)
    ActiveRecord::Base.default_connection_handler = @original_default_handler
    ActiveRecord::Base.connection_handler = @original_handler
    FileUtils.remove_entry(@directory) if @directory
  end

  test "simultaneous first visits show only one introduction" do
    first, second = concurrent_openings

    assert first.value.fetch("showPrototypeInfo")
    assert_not second.value.fetch("showPrototypeInfo")
    assert_equal 1, PrototypeIntroduction.count
  end

  test "a competing first visit gets the introduction when the first render fails" do
    first, second = concurrent_openings(fail_first: true)

    error = first.value
    assert_instance_of ActionView::Template::Error, error
    assert_includes error.message, "First introduction render failed"
    assert second.value.fetch("showPrototypeInfo")
    assert_equal 1, PrototypeIntroduction.count
  end

  private

  def concurrent_openings(fail_first: false)
    github_app_configurations.create_installed
    payload = repository_payload(2001, "github/prototype")
    stub_github_sign_in(repositories: [ payload ], permissions: { 2001 => "pull" })
    browsers = 2.times.map do
      open_session do |browser|
        browser.post github_authentication_path
        state = Rack::Utils.parse_query(URI(browser.response.location).query).fetch("state")
        browser.get github_authentication_callback_path, params: { code: "code", state: }
        assert_equal 302, browser.response.status
      end
    end
    prototype = prototypes.create(repository: Repository.find_by!(github_id: 2001))
    path = repository_prototype_path(prototype.repository.github_id, prototype)
    rendering = Queue.new
    competing = Queue.new
    release = Queue.new
    original_render = PreviewControlsHelper.instance_method(:preview_controls_identity)
    original_record = PrototypeIntroduction.method(:record!)
    workers = []

    begin
      PrototypeIntroduction.define_singleton_method(:record!) do |**attributes|
        competing << true if Thread.current[:introduction_request] == :second
        original_record.call(**attributes)
      end
      PreviewControlsHelper.define_method(:preview_controls_identity) do |*args, **kwargs|
        if Thread.current[:introduction_request] == :first
          rendering << true
          raise "First introduction render timed out" unless release.pop(timeout: 5)
          raise "First introduction render failed" if fail_first
        elsif Thread.current[:introduction_request] == :second
          competing << true
        end
        original_render.bind_call(self, *args, **kwargs)
      end

      workers << open_in_thread(browsers.first, path, :first)
      assert rendering.pop(timeout: 5), "First request did not reach rendering"
      assert_equal 0, PrototypeIntroduction.count, "The claim must remain uncommitted while rendering"
      workers << open_in_thread(browsers.second, path, :second)
      assert competing.pop(timeout: 5), "Second request did not compete for the introduction"
      release << true
      workers.each { |worker| assert worker.join(10), "Concurrent request did not finish" }
      workers
    ensure
      begin
        release << true
        workers.each { |worker| worker.join(10) }
      ensure
        PrototypeIntroduction.define_singleton_method(:record!, original_record)
        PreviewControlsHelper.define_method(:preview_controls_identity, original_render)
      end
    end
  end

  def open_in_thread(browser, path, identity)
    Thread.new do
      Thread.current.report_on_exception = false
      Thread.current[:introduction_request] = identity
      Rails.application.executor.wrap do
        browser.get path, headers: { "Accept" => "application/json" }
        assert_equal 200, browser.response.status
        JSON.parse(browser.response.body).fetch("data")
      end
    rescue ActionView::Template::Error => error
      error
    end
  end
end
