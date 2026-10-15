require "test_helper"

class GithubWebhooksTest < ActionDispatch::IntegrationTest
  test "does not reveal whether an App is configured" do
    post github_webhooks_path, params: "{}", headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end

  test "rejects an invalid signature" do
    github_app_configurations.create

    post github_webhooks_path, params: "{}", headers: {
      "Content-Type" => "application/json",
      "X-GitHub-Delivery" => "delivery-1",
      "X-GitHub-Event" => "installation",
      "X-Hub-Signature-256" => "sha256=wrong"
    }

    assert_response :unauthorized
  end

  test "does not reveal configuration through oversized requests" do
    headers = {
      "Content-Type" => "application/json",
      "Content-Length" => (GithubWebhook::MAXIMUM_BODY_SIZE + 1).to_s
    }

    post github_webhooks_path, params: "", headers: headers
    assert_response :content_too_large

    github_app_configurations.create
    post github_webhooks_path, params: "", headers: headers
    assert_response :content_too_large
  end


  test "accepts an authenticated push and records its delivery" do
    configuration = github_app_configurations.create_installed
    repository = repositories.create
    body = JSON.generate \
      installation: { id: 456 },
      repository: { id: repository.github_id, default_branch: "main" },
      ref: "refs/heads/prototype/welcome",
      before: "a" * 40,
      after: "b" * 40,
      deleted: false
    signature = OpenSSL::HMAC.hexdigest("SHA256", configuration.webhook_secret, body)

    post github_webhooks_path, params: body, headers: {
      "Content-Type" => "application/json",
      "X-GitHub-Delivery" => "push-1",
      "X-GitHub-Event" => "push",
      "X-Hub-Signature-256" => "sha256=#{signature}"
    }

    assert_response :accepted
    assert_equal 1, Build.count
    assert WebhookDelivery.find_by!(github_delivery_id: "push-1").processed?
  end
end
