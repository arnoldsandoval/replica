require "test_helper"

class Build::WorkflowRunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "records successful workflow completion while import remains pending" do
    build = builds.create

    assert_enqueued_with(job: Build::ImportPackageJob) do
      build.workflow_run.record! \
        run_id: 9001,
        run_attempt: 1,
        workflow_url: "https://github.com/github/prototype/actions/runs/9001",
        workflow_created_at: Time.iso8601("2026-09-17T18:00:00Z"),
        stage: "completed",
        conclusion: "success"
    end

    assert_equal "running", build.state
    assert_predicate build.workflow_completed_at, :present?
    assert_predicate build.package_import, :pending?
    assert_includes Build.awaiting_import, build
  end

  test "fails a Build when GitHub no longer provides its saved run" do
    build = builds.create
    build.workflow_run.record! \
      run_id: 9001,
      run_attempt: 1,
      workflow_url: "https://github.com/github/prototype/actions/runs/9001",
      workflow_created_at: Time.iso8601("2026-09-17T18:00:00Z"),
      stage: "requested",
      conclusion: nil

    assert build.workflow_run.fail_missing!

    assert_equal "failed", build.state
    assert_equal "GitHub no longer provides this build's workflow run.", build.failure_summary
    assert_predicate build.started_at, :present?
    assert_predicate build.finished_at, :present?
  end

  test "does not replace successful completion with a later failure" do
    build = builds.create
    attributes = {
      run_id: 9001,
      run_attempt: 1,
      workflow_url: "https://github.com/github/prototype/actions/runs/9001",
      workflow_created_at: Time.iso8601("2026-09-17T18:00:00Z")
    }
    build.workflow_run.record!(**attributes, stage: "completed", conclusion: "success")
    completed_at = build.workflow_completed_at

    build.workflow_run.record!(**attributes, stage: "completed", conclusion: "failure")

    assert_equal "running", build.reload.state
    assert_equal completed_at, build.workflow_completed_at
    assert_nil build.failure_summary
  end

  test "backfills GitHub chronology for a completed legacy Build" do
    time = Time.current
    build = builds.create
    build.update! \
      state: "failed",
      started_at: time,
      finished_at: time,
      failure_summary: "GitHub Actions finished with failure.",
      github_workflow_run_id: 9001,
      github_workflow_run_attempt: 1,
      workflow_url: "https://github.com/github/prototype/actions/runs/9001"
    workflow_created_at = Time.iso8601("2026-09-17T18:00:00Z")

    build.workflow_run.record! \
      run_id: 9001,
      run_attempt: 1,
      workflow_url: build.workflow_url,
      workflow_created_at:,
      stage: "completed",
      conclusion: "failure"

    assert_equal workflow_created_at, build.reload.workflow_created_at
    assert_equal "failed", build.state
  end

  test "recognizes workflow links on the configured GitHub website" do
    assert Build::WorkflowRun.github_url?("https://github.com/github/prototype/actions/runs/9001")
    assert_not Build::WorkflowRun.github_url?("https://example.com/github/prototype/actions/runs/9001")
  end
end
