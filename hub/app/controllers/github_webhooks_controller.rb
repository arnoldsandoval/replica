# Receives signed GitHub App webhooks without a browser session.
class GithubWebhooksController < ActionController::API
  include SecurityRateLimiting
  MAXIMUM_BODY_SIZE = GithubWebhook::MAXIMUM_BODY_SIZE

  # @route POST /github/webhooks (github_webhooks)
  def create
    return head :not_found if LocalDevelopment.enabled?

    return head :content_too_large if request.content_length.to_i > MAXIMUM_BODY_SIZE

    body = request.body.read(MAXIMUM_BODY_SIZE + 1)
    return head :content_too_large if body.bytesize > MAXIMUM_BODY_SIZE

    configuration = GithubAppConfiguration.current
    return head :unauthorized if configuration.nil?

    GithubWebhook.process! \
      configuration:,
      body:,
      delivery_id: request.headers["X-GitHub-Delivery"],
      event: request.headers["X-GitHub-Event"],
      signature: request.headers["X-Hub-Signature-256"] do |delivery, installation_id|
        admitted = enforce_security_rate_limit(:webhooks, identity: "hub")
        WebhookRedelivery.record_throttle!(configuration:, delivery:, installation_id:) if !admitted
        admitted
      end
    head :accepted if !performed?
  rescue GithubWebhook::Rejected
    head :unauthorized
  rescue GithubClient::Error,
    GithubAppConfiguration::Installation::OwnerMismatch,
    GithubAppConfiguration::Superseded,
    ActiveRecord::StaleObjectError
    head :service_unavailable
  end
end
