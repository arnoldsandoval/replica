require "test_helper"
require "tmpdir"

class ArtifactRespondableTest < ActionController::TestCase
  class TestController < ActionController::Base
    include ArtifactRespondable

    def show
      send_artifact("builds/1/dist/index.html", content_type: "text/html")
    end
  end

  tests TestController

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw { get "show" => "artifact_respondable_test/test#show" }
  end

  test "returns unavailable before sending a storage failure" do
    store = Object.new
    store.define_singleton_method(:read) do |_name, destination:|
      destination.write("partial")
      raise ArtifactStore::TemporaryError, "interrupted"
    end

    current = ArtifactStore.method(:current)
    ArtifactStore.define_singleton_method(:current) { store }
    get :show

    assert_response :service_unavailable
    assert_empty response.body
  ensure
    ArtifactStore.define_singleton_method(:current, current) if current
  end
end
