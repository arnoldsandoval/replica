# Performs candidate identity checks and fixed-endpoint webhook updates without transactions.
class GithubAppConfiguration::Rotator < ActiveRecord::AssociatedObject
  class IdentityMismatch < StandardError; end

  # A candidate key proves App identity; it does not verify the OAuth client secret.
  def verify_credentials!(client_secret:, private_key:)
    limits = GithubAppConfiguration::Administration
    valid = client_secret.is_a?(String) && client_secret.present? &&
      client_secret.bytesize <= limits::CLIENT_SECRET_LIMIT &&
      private_key.is_a?(String) && private_key.present? &&
      private_key.bytesize <= limits::PRIVATE_KEY_LIMIT
    raise limits::InvalidCredentials, "Invalid replacement credentials" if !valid

    key = OpenSSL::PKey::RSA.new(private_key)
    raise limits::InvalidCredentials, "Invalid replacement credentials" if !key.private?

    candidate = record.dup
    candidate.client_secret = client_secret
    candidate.private_key = private_key
    verify_identity!(candidate.github_client.apps.get(token: candidate.tokens.app))
  rescue OpenSSL::PKey::RSAError, ArgumentError
    raise GithubAppConfiguration::Administration::InvalidCredentials, "Invalid replacement credentials"
  end

  # The saved pending secret is retried unchanged; it never enters a browser response.
  def update_webhook!
    record.github_client.apps.update_webhook \
      url: "#{Rails.configuration.x.hub_origin.delete_suffix("/")}/github/webhooks",
      secret: record.webhook_secret,
      token: record.tokens.app
  end

  private

  # Refuses credentials for another App or owner regardless of mutable display names.
  def verify_identity!(app)
    raise IdentityMismatch, "GitHub returned incomplete App identity" if
      !app.is_a?(Hash) || !app["owner"].is_a?(Hash)

    owner = app.fetch("owner")
    valid = app.fetch("id").is_a?(Integer) && app.fetch("id") == record.github_app_id &&
      owner.fetch("id").is_a?(Integer) && owner.fetch("id") == record.owner_github_id &&
      owner.fetch("type") == record.owner_type
    raise IdentityMismatch, "Replacement credentials belong to another GitHub App" if !valid
  rescue KeyError, TypeError, ArgumentError
    raise IdentityMismatch, "GitHub returned incomplete App identity"
  end
end
