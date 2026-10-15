require "test_helper"

class Learning::StoreTest < ActiveSupport::TestCase
  include LearningTestHelpers

  %w[repositories repository].each do |component|
    test "refuses a symlink at the #{component} component before touching its target" do
      repository = repositories.create
      store = Learning::Store.new(repository)
      Dir.mktmpdir("replica-learning-public-", Rails.public_path) do |target|
        File.chmod(0o750, target)
        sentinel = File.join(target, "sentinel")
        File.write(sentinel, "Unchanged public test content.")
        delayed_command = store.command("status")
        link = Rails.configuration.x.learning_root.join("repositories")
        if component == "repository"
          link.mkpath
          link = link.join(repository.id.to_s)
        end
        File.symlink(target, link)

        [
          -> { store.prepare! },
          -> { store.directory },
          -> { store.exist? },
          -> { store.command("status") },
          -> { store.call("status") },
          -> { store.remove_comment!("1", by: "github:octocat") },
          delayed_command
        ].each do |operation|
          error = assert_raises(Learning::Error, &operation)
          assert_equal "unavailable", error.code
        end

        assert_equal 0o750, File.stat(target).mode & 0o777
        assert_equal [ "sentinel" ], Dir.children(target)
        assert_equal "Unchanged public test content.", File.read(sentinel)
      end
    end
  end
end
