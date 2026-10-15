require "test_helper"

class Learning::OverviewTest < ActiveSupport::TestCase
  include LearningTestHelpers

  setup do
    github_app_configurations.create_installed
    @admin = users.create(hub_admin: true)
    connect_copilot(@admin)
    @repository = repositories.create
    @mona = users.create(github_id: 1_002, login: "mona")
    @hubot = users.create(github_id: 1_003, login: "hubot")
    use_test_labeler(@repository)
  end

  test "shows the complete stored wording behind a suggestion, not a later Hub edit" do
    original = "The email field has no label. #{"This matters to reviewers. " * 20}"
    comment = learning_comment(@repository, @mona, "prototype/signup", original)
    learning_comment(@repository, @hubot, "prototype/checkout", "The card number needs a visible label.")
    Learning::Run.request!(repository: @repository, user: @admin).find_learnings!
    travel 1.minute
    comment.thread.edit_body!("The field now has a visible label.", actor: @mona)

    suggestion = overview[:suggestions].sole
    evidence = suggestion[:evidence].find { _1[:commentId] == comment.id }

    assert_equal original, evidence[:body]
    assert_match(/\Aev_/, evidence[:eventId])
    assert_equal 0, suggestion[:otherEvidence]
    assert_equal 2, suggestion[:evidence].size
  end

  test "shows opposing evidence separately and counts opposing comments Hub cannot show" do
    learning_comment(@repository, @mona, "prototype/signup", "The email field has no label.")
    learning_comment(@repository, @hubot, "prototype/checkout", "The card number needs a visible label.")
    opposing = learning_comment(@repository, @admin, "prototype/account", "I disagree: the field has a label already.")
    Learning::Run.request!(repository: @repository, user: @admin).find_learnings!

    suggestion = overview[:suggestions].sole

    assert_equal 2, suggestion[:evidence].size
    assert_equal [ opposing.body ], suggestion[:contradictions].pluck(:body)
    assert_equal 0, suggestion[:otherContradictions]

    opposing.prototype.update!(replica: true)
    unavailable = overview[:suggestions].sole
    assert_empty unavailable[:contradictions]
    assert_equal 1, unavailable[:otherContradictions]
    assert_equal 0, unavailable[:otherEvidence]
  end

  test "does not show stored text after the Hub author deletes the comment" do
    deleted = learning_comment(@repository, @mona, "prototype/signup", "The email field has no label.")
    learning_comment(@repository, @hubot, "prototype/checkout", "The card number needs a visible label.")
    Learning::Run.request!(repository: @repository, user: @admin).find_learnings!
    deleted.thread.delete_body!(actor: @mona)

    evidence = overview[:suggestions].sole[:evidence].find { _1[:commentId] == deleted.id }

    assert_nil evidence[:body]
  end

  test "keeps a valid suggestion without optional support counts reviewable" do
    use_test_consolidator_without_support(@repository)
    learning_comment(@repository, @mona, "prototype/signup", "The email field has no label.")
    learning_comment(@repository, @hubot, "prototype/checkout", "The card number needs a visible label.")
    run = Learning::Run.request!(repository: @repository, user: @admin).tap(&:find_learnings!)
    assert_equal "succeeded", run.state, run.failure_summary

    suggestion = overview[:suggestions].sole

    assert_nil suggestion[:reviewers]
    assert_nil suggestion[:prototypes]
    assert_equal 2, suggestion[:evidence].size
    assert_match(/\Asha256:/, suggestion[:reviewDigest])
  end

  test "reads supporting and opposing evidence in batches of at most 100 exact events" do
    101.times do |index|
      user, branch = index.even? ? [ @mona, "prototype/signup" ] : [ @hubot, "prototype/checkout" ]
      learning_comment(@repository, user, branch, "Field #{index} needs a visible label.")
    end
    learning_comment(@repository, @admin, "prototype/account", "I disagree: these fields have visible labels.")
    Learning::Run.request!(repository: @repository, user: @admin).find_learnings!
    store = Learning::Store.new(@repository)
    queries = []
    original = store.method(:command)
    store.define_singleton_method(:command) do |*arguments, **options|
      queries << arguments if arguments.first == "observations"
      original.call(*arguments, **options)
    end

    loaded = Learning::Overview.new(store, viewer: Learning.person_for(@admin)).load

    requested = queries.map { _1.each_cons(2).filter_map { |flag, id| id if flag == "--event" } }
    assert_equal [ 100, 2 ], requested.map(&:size)
    assert_equal 102, requested.flatten.uniq.size
    assert_equal 101, loaded[:suggestions].sole[:evidence].size
    assert_equal 1, loaded[:suggestions].sole[:contradictions].size
  end

  test "unrelated stored comments cannot overflow the evidence response for a suggestion" do
    learning_comment(@repository, @mona, "prototype/signup", "The email field has no label.")
    learning_comment(@repository, @hubot, "prototype/checkout", "The card number needs a visible label.")
    8.times { learning_comment(@repository, @mona, "prototype/signup", "Nice colors. " * 700) }
    Learning::Run.request!(repository: @repository, user: @admin).find_learnings!
    store = Learning::Store.new(@repository)
    previous = Learning::Command::OUTPUT_LIMIT
    Learning::Command.send(:remove_const, :OUTPUT_LIMIT)
    Learning::Command.const_set(:OUTPUT_LIMIT, 40.kilobytes)

    error = assert_raises(Learning::Error) { store.call("observations", "--purpose", "review", "--type", "human_comment") }
    assert_equal "output_too_large", error.code
    loaded = Learning::Overview.new(store, viewer: Learning.person_for(@admin)).load
    assert_equal 2, loaded[:suggestions].sole[:evidence].size
  ensure
    if previous
      Learning::Command.send(:remove_const, :OUTPUT_LIMIT)
      Learning::Command.const_set(:OUTPUT_LIMIT, previous)
    end
  end

  test "accepted learnings with no displayed suggestions need no observation query" do
    learning_comment(@repository, @mona, "prototype/signup", "The email field has no label.")
    learning_comment(@repository, @hubot, "prototype/checkout", "The card number needs a visible label.")
    Learning::Run.request!(repository: @repository, user: @admin).find_learnings!
    store = Learning::Store.new(@repository)
    proposal = store.call("memories").sole.fetch("record")
    store.call("accept", proposal.fetch("id"), "--digest=#{proposal.fetch("reviewDigest")}", "--by", "github:octocat")
    original = store.method(:command)
    store.define_singleton_method(:command) do |*arguments, **options|
      raise "An empty reference set must not query observations" if arguments.first == "observations"

      original.call(*arguments, **options)
    end

    loaded = Learning::Overview.new(store, viewer: Learning.person_for(@admin)).load

    assert_empty loaded[:suggestions]
    assert_equal 1, loaded[:learnings].size
    assert_equal 1, loaded.dig(:recall, :count)
  end

  test "a recallable learning with a later replacement conflict is not reported as damaged" do
    learning_comment(@repository, @mona, "prototype/signup", "The email field has no label.")
    learning_comment(@repository, @hubot, "prototype/checkout", "The card number needs a visible label.")
    Learning::Run.request!(repository: @repository, user: @admin).find_learnings!
    store = Learning::Store.new(@repository)
    proposal = store.call("memories").sole.fetch("record")
    store.call("accept", proposal.fetch("id"), "--digest=#{proposal.fetch("reviewDigest")}", "--by", "github:octocat")
    original = store.method(:command)
    store.define_singleton_method(:command) do |*arguments, **options|
      command = original.call(*arguments, **options)
      next command if arguments.first != "memories"

      -> {
        command.call.map do |item|
          item.merge("status" => item.fetch("status").merge("conflicts" => [ "Another replacement came first." ]))
        end
      }
    end

    loaded = Learning::Overview.new(store, viewer: Learning.person_for(@admin)).load

    assert_equal false, loaded[:learnings].sole[:damaged]
    assert_equal true, loaded[:learnings].sole[:recalled]
    assert_equal proposal.fetch("content"), loaded[:learnings].sole[:content]
    assert_equal 1, loaded.dig(:recall, :count)
  end

  test "shows every replacement target and respects withheld target wording" do
    learning_comment(@repository, @mona, "prototype/signup", "The email field has no label.")
    learning_comment(@repository, @hubot, "prototype/checkout", "The card number needs a visible label.")
    learning_comment(@repository, @mona, "prototype/signup", "The hint text needs more contrast.")
    learning_comment(@repository, @hubot, "prototype/checkout", "The price has too little contrast.")
    Learning::Run.request!(repository: @repository, user: @admin).find_learnings!
    store = Learning::Store.new(@repository)
    targets = store.call("memories").map do |item|
      record = item.fetch("record")
      store.call("accept", record.fetch("id"), "--digest=#{record.fetch("reviewDigest")}", "--by", "github:octocat")
    end
    assert_equal 2, targets.size
    use_test_merge_consolidator(@repository)
    run = Learning::Run.request!(repository: @repository, user: @admin).tap(&:find_learnings!)
    assert_equal "succeeded", run.state, run.failure_summary

    suggestion = Learning::Overview.new(store, viewer: "github:octocat").load[:suggestions].sole

    expected = targets.to_h { [ _1.fetch("id"), _1.fetch("content") ] }
    assert_equal expected, suggestion[:replaces].to_h { [ _1[:id], _1[:content] ] }
    hidden = targets.first.fetch("id")
    original = store.method(:command)
    store.define_singleton_method(:command) do |*arguments, **options|
      command = original.call(*arguments, **options)
      next command if arguments.first != "memories"

      -> {
        command.call.map do |item|
          item.dig("record", "id") == hidden ?
            item.merge("withheld" => true, "record" => item.fetch("record").except("content")) : item
        end
      }
    end

    limited = Learning::Overview.new(store, viewer: "github:octocat").load[:suggestions].sole
    assert_equal targets.pluck("id").sort, limited[:replaces].pluck(:id).sort
    assert_nil limited[:replaces].find { _1[:id] == hidden }[:content]
    assert_equal 1, limited[:replaces].count { _1[:content].present? }
    store.call("accept", suggestion[:id], "--digest=#{suggestion[:reviewDigest]}", "--by", "github:octocat")
    assert_equal [ suggestion[:id] ], store.call("recall", "--preview", "--by", "github:octocat").fetch("memories").pluck("id")
  end

  test "marks an eligible learning left out by the text budget differently from a recalled one" do
    learning_comment(@repository, @mona, "prototype/signup", "The email field has no label.")
    learning_comment(@repository, @hubot, "prototype/checkout", "The card number needs a visible label.")
    learning_comment(@repository, @mona, "prototype/signup", "The contrast on the hint is too low.")
    learning_comment(@repository, @hubot, "prototype/checkout", "The contrast on the total is too low.")
    Learning::Run.request!(repository: @repository, user: @admin).find_learnings!
    store = Learning::Store.new(@repository)
    store.call("memories").each do |item|
      proposal = item.fetch("record")
      Tempfile.create([ "long-learning-", ".txt" ]) do |file|
        file.write("Long approved guidance. " * 165)
        file.flush
        store.call \
          "accept", proposal.fetch("id"), "--digest=#{proposal.fetch("reviewDigest")}",
          "--by", Learning.person_for(@admin), "--content-file", file.path
      end
    end

    loaded = overview

    assert_equal 1, loaded.dig(:recall, :count)
    assert_equal [ false, true ], loaded[:learnings].pluck(:recalled).sort_by(&:to_s)
    assert_equal [ false, true ], loaded[:learnings].pluck(:budgetExcluded).sort_by(&:to_s)
  end

  private

  # Reads the real store as the signed-in administrator, without recording a recall use.
  def overview
    Learning::Overview.new(Learning::Store.new(@repository), viewer: Learning.person_for(@admin)).load
  end
end
