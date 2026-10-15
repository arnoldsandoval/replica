# Calls GitHub APIs for App setup, identity, and webhook configuration.
class GithubClient::Apps
  # Uses the shared GitHub API transport.
  def initialize(transport)
    @transport = transport
  end

  # Exchanges one App Manifest code for GitHub App credentials.
  def manifest(code)
    transport.request \
      :post,
      "/app-manifests/#{CGI.escape(code.to_s)}/conversions",
      expected_status: [ 201 ]
  end

  # Fetches the GitHub App authenticated by the provided token.
  def get(token:)
    transport.request(:get, "/app", token:)
  end

  # Gives GitHub a new webhook URL and shared secret.
  def update_webhook(url:, secret:, token:)
    transport.request \
      :patch,
      "/app/hook/config",
      token:,
      body: { url:, content_type: "json", secret:, insecure_ssl: "0" }
  end

  private

  attr_reader :transport
end
