require "test_helper"
require "open3"
require "tmpdir"

class ReviewProseTest < ActiveSupport::TestCase
  REVIEW_PROSE = Rails.root.join("bin/review-prose").to_s

  test "shows committed and untracked Markdown and code comments" do
    Dir.mktmpdir("replica-review-prose-") do |directory|
      repository = Pathname(directory)
      initialize_repository(repository)
      base = run_git(repository, "rev-parse", "HEAD").strip

      write(repository.join("docs/guide.md"), "# Updated guide\n\nHub stores comments.\n")
      write \
        repository.join("app/example.ts"),
        "/*\nKeep this value local.\n*/\nexport const value = 2\n"
      commit_all(repository, "update tracked prose")

      write(repository.join("notes/new.md"), "# New notes\n\nThe bridge finds elements.\n")
      write(repository.join("app/new.rb"), "# Explains why this value is fixed.\nVALUE = 1\n")

      output, status = Open3.capture2e(REVIEW_PROSE, base, chdir: repository)

      assert status.success?, output
      assert_includes output, "--- docs/guide.md ---"
      assert_includes output, "Hub stores comments."
      assert_includes output, "--- notes/new.md ---"
      assert_includes output, "The bridge finds elements."
      assert_includes output, "--- app/example.ts ---"
      assert_includes output, "1:/*"
      assert_includes output, "2:Keep this value local."
      assert_includes output, "3:*/"
      assert_includes output, "--- app/new.rb ---"
      assert_includes output, "1:# Explains why this value is fixed."
      assert_not_includes output, "export const value = 2"
      assert_not_includes output, "VALUE = 1"
    end
  end

  test "shows comments in scoped extensionless scripts" do
    Dir.mktmpdir("replica-review-prose-") do |directory|
      repository = Pathname(directory)
      initialize_repository(repository)
      base = run_git(repository, "rev-parse", "HEAD").strip
      write(repository.join("hub/bin/check"), "# Explains why this check runs.\nprintf 'ok\\n'\n")

      output, status = Open3.capture2e(REVIEW_PROSE, base, chdir: repository.join("hub"))

      assert status.success?, output
      assert_includes output, "--- hub/bin/check ---"
      assert_includes output, "1:# Explains why this check runs."
      assert_not_includes output, "printf 'ok"
    end
  end

  private

  def initialize_repository(repository)
    run_git repository, "init", "--quiet"
    run_git repository, "config", "user.name", "Replica"
    run_git repository, "config", "user.email", "replica@example.com"
    write(repository.join("docs/guide.md"), "# Original guide\n")
    write(repository.join("app/example.ts"), "export const value = 1\n")
    commit_all(repository, "initial files")
  end

  def commit_all(repository, message)
    run_git repository, "add", "."
    run_git repository, "commit", "--quiet", "--message", message
  end

  def run_git(repository, *arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: repository)
    assert status.success?, output
    output
  end

  def write(path, content)
    path.dirname.mkpath
    path.write(content)
  end
end
